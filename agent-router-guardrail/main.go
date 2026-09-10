// agent-router-guardrail — an Envoy ext_proc server that guards LLM traffic
// through Agent Router (formerly Envoy AI Gateway). Two directions:
//
//   REQUEST  (prompt): block prompts containing "execute" -> HTTP 403
//   RESPONSE (completion): mask emails + the word "secret" in the answer
//
// This is the same guardrail idea we built for agentgateway, but here it runs
// on REAL Envoy — so ImmediateResponse(403) AND response-body mutation both
// work (agentgateway v1.2.1 ext_proc could do neither).
//
// Wired via Envoy Gateway EnvoyExtensionPolicy (spec.extProc) with
// processingMode.request.body: Buffered and processingMode.response.body:
// Buffered, attached to the AIGatewayRoute's generated HTTPRoute(s).
package main

import (
	"encoding/json"
	"io"
	"log"
	"net"
	"regexp"
	"strings"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extprocv3 "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/grpc"
)

// Request-side rules (case-insensitive substring match on the body).
var (
	llmBlock = []string{"execute"}                // LLM: block "execute …", allow "teach me …"
	mcpBlock = []string{"deploy", "execute this"} // MCP (if an MCPRoute is guarded too)
)

// Response-side masking: redact emails (PII) and the word "secret".
var (
	emailRe  = regexp.MustCompile(`[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}`)
	secretRe = regexp.MustCompile(`(?i)secret`)
)

func maskContent(s string) (string, bool) {
	out := emailRe.ReplaceAllString(s, "[REDACTED-EMAIL]")
	out = secretRe.ReplaceAllString(out, "[REDACTED]")
	return out, out != s
}

type server struct {
	extprocv3.UnimplementedExternalProcessorServer
}

func headerValue(h *corev3.HeaderValue) string {
	if h.GetValue() != "" {
		return h.GetValue()
	}
	return string(h.GetRawValue())
}

// evaluate returns (blocked, leg, reason). Agent Router's LLM path is
// /v1/chat/completions, so unless the path is an MCP path we treat it as LLM.
func evaluate(path string, body []byte) (bool, string, string) {
	text := strings.ToLower(string(body))
	p := strings.ToLower(path)

	var leg string
	var keywords []string
	switch {
	case strings.Contains(p, "mcp"):
		leg, keywords = "MCP", mcpBlock
	default:
		leg, keywords = "LLM", llmBlock
	}

	detail := summarize(leg, body)
	for _, kw := range keywords {
		if strings.Contains(text, kw) {
			return true, leg, "matched blocked keyword \"" + kw + "\"" + detail
		}
	}
	return false, leg, "no blocked keyword" + detail
}

func summarize(leg string, body []byte) string {
	switch leg {
	case "MCP":
		var m struct {
			Method string `json:"method"`
			Params struct {
				Name      string                 `json:"name"`
				Arguments map[string]interface{} `json:"arguments"`
			} `json:"params"`
		}
		if json.Unmarshal(body, &m) == nil && m.Method != "" {
			q, _ := m.Params.Arguments["query"].(string)
			return " [method=" + m.Method + " tool=" + m.Params.Name + " query=\"" + q + "\"]"
		}
	case "LLM":
		var m struct {
			Model    string `json:"model"`
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
		}
		if json.Unmarshal(body, &m) == nil && len(m.Messages) > 0 {
			last := m.Messages[len(m.Messages)-1].Content
			if len(last) > 60 {
				last = last[:60] + "…"
			}
			return " [model=" + m.Model + " last_msg=\"" + last + "\"]"
		}
	}
	return ""
}

func (s *server) Process(stream extprocv3.ExternalProcessor_ProcessServer) error {
	var path string
	var reqBuf, respBuf []byte
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		switch v := req.Request.(type) {

		case *extprocv3.ProcessingRequest_RequestHeaders:
			for _, h := range v.RequestHeaders.GetHeaders().GetHeaders() {
				if h.GetKey() == ":path" {
					path = headerValue(h)
				}
			}
			log.Printf("→ request headers, path=%s", path)
			if err := stream.Send(&extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_RequestHeaders{
					RequestHeaders: &extprocv3.HeadersResponse{},
				},
			}); err != nil {
				return err
			}

		case *extprocv3.ProcessingRequest_RequestBody:
			chunk := v.RequestBody.GetBody()
			eos := v.RequestBody.GetEndOfStream()
			reqBuf = append(reqBuf, chunk...)
			if !eos {
				stream.Send(&extprocv3.ProcessingResponse{
					Response: &extprocv3.ProcessingResponse_RequestBody{RequestBody: &extprocv3.BodyResponse{}},
				})
				continue
			}
			log.Printf("→ request body total=%d", len(reqBuf))

			blocked, leg, reason := evaluate(path, reqBuf)
			if blocked {
				log.Printf("⛔ BLOCK  leg=%s path=%s — %s", leg, path, reason)
				msg := "Blocked by intent guardrail (" + leg + "): " + reason + "\n"
				if err := stream.Send(&extprocv3.ProcessingResponse{
					Response: &extprocv3.ProcessingResponse_ImmediateResponse{
						ImmediateResponse: &extprocv3.ImmediateResponse{
							Status: &typev3.HttpStatus{Code: typev3.StatusCode_Forbidden},
							Body:   []byte(msg),
						},
					},
				}); err != nil {
					return err
				}
				continue
			}
			log.Printf("✅ ALLOW  leg=%s path=%s — %s", leg, path, reason)
			if err := stream.Send(&extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_RequestBody{
					RequestBody: &extprocv3.BodyResponse{
						Response: &extprocv3.CommonResponse{
							BodyMutation: &extprocv3.BodyMutation{
								Mutation: &extprocv3.BodyMutation_Body{Body: reqBuf},
							},
						},
					},
				},
			}); err != nil {
				return err
			}

		case *extprocv3.ProcessingRequest_ResponseHeaders:
			// Continue; the response body arrives next because the policy sets
			// processingMode.response.body: Buffered.
			if err := stream.Send(&extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_ResponseHeaders{
					ResponseHeaders: &extprocv3.HeadersResponse{},
				},
			}); err != nil {
				return err
			}

		case *extprocv3.ProcessingRequest_ResponseBody:
			chunk := v.ResponseBody.GetBody()
			eos := v.ResponseBody.GetEndOfStream()
			respBuf = append(respBuf, chunk...)
			if !eos {
				stream.Send(&extprocv3.ProcessingResponse{
					Response: &extprocv3.ProcessingResponse_ResponseBody{ResponseBody: &extprocv3.BodyResponse{}},
				})
				continue
			}
			masked, changed := maskContent(string(respBuf))
			if changed {
				log.Printf("🟡 MASK   response — redacted email/secret in completion")
			} else {
				log.Printf("✅ PASS   response — nothing to redact")
			}
			if err := stream.Send(&extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_ResponseBody{
					ResponseBody: &extprocv3.BodyResponse{
						Response: &extprocv3.CommonResponse{
							BodyMutation: &extprocv3.BodyMutation{
								Mutation: &extprocv3.BodyMutation_Body{Body: []byte(masked)},
							},
						},
					},
				},
			}); err != nil {
				return err
			}

		default:
			if err := stream.Send(&extprocv3.ProcessingResponse{}); err != nil {
				return err
			}
		}
	}
}

func main() {
	lis, err := net.Listen("tcp", ":18080")
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	s := grpc.NewServer()
	extprocv3.RegisterExternalProcessorServer(s, &server{})
	log.Printf("agent-router-guardrail ext_proc on :18080  (req block=%v, resp mask=email+secret)", llmBlock)
	if err := s.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
