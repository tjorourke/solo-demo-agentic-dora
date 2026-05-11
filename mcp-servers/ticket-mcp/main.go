// ticket-mcp — TrustUsBank ticketing & human-escalation MCP server.
//
// Framework note: this server is written in Go. Tool functions are declared
// as Google ADK FunctionTools (google.golang.org/adk/tool/functiontool), and
// then bridged onto the MCP wire via the official MCP Go SDK
// (github.com/modelcontextprotocol/go-sdk/mcp).
//
// This is deliberate framework variety. transaction-mcp is Python + ADK,
// account-mcp / currency-converter are Python + FastMCP, the agents are
// kagent Declarative, and this one is Go + ADK + MCP Go SDK. The wire
// protocol (MCP over streamable HTTP on :8080) is identical so the rest of
// the bank's stack (agentgateway, support-bot, fraud-bot, triage-bot)
// doesn't know or care.
//
// Tools:
//   - create_ticket(customer_id, summary, severity)
//   - notify_human(ticket_id, channel)
//
// Every ticket is a DORA Art. 17 incident record.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"google.golang.org/adk/tool"
	"google.golang.org/adk/tool/functiontool"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdkresource "go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// ---------- State ----------

type ticket struct {
	TicketID      string              `json:"ticket_id"`
	CustomerID    string              `json:"customer_id"`
	Summary       string              `json:"summary"`
	Severity      string              `json:"severity"`
	Status        string              `json:"status"`
	CreatedAt     string              `json:"created_at"`
	Notifications []map[string]string `json:"notifications,omitempty"`
}

var (
	ticketsMu sync.Mutex
	tickets   = map[string]*ticket{}
	tracer    = otel.Tracer("ticket-mcp")
)

// ---------- Tool args / results ----------

type CreateTicketArgs struct {
	CustomerID string `json:"customer_id"           jsonschema:"the customer ID the ticket relates to"`
	Summary    string `json:"summary"               jsonschema:"a short human-readable summary of the issue"`
	Severity   string `json:"severity,omitempty"    jsonschema:"one of: low, medium, high, critical (default medium)"`
}

type NotifyHumanArgs struct {
	TicketID string `json:"ticket_id"           jsonschema:"the ID returned by create_ticket"`
	Channel  string `json:"channel,omitempty"   jsonschema:"one of: slack, email, pager (default slack)"`
}

// ---------- Core logic (shared by ADK + MCP facades) ----------

func newTicketID() string {
	var buf [4]byte
	_, _ = rand.Read(buf[:])
	return "TICK-" + strings.ToUpper(hex.EncodeToString(buf[:]))
}

func createTicket(ctx context.Context, args CreateTicketArgs) map[string]any {
	ctx, span := tracer.Start(ctx, "create_ticket")
	defer span.End()

	sev := args.Severity
	if sev == "" {
		sev = "medium"
	}
	valid := map[string]struct{}{"low": {}, "medium": {}, "high": {}, "critical": {}}
	if _, ok := valid[sev]; !ok {
		return map[string]any{"error": "invalid severity", "got": sev}
	}

	id := newTicketID()
	t := &ticket{
		TicketID:   id,
		CustomerID: args.CustomerID,
		Summary:    args.Summary,
		Severity:   sev,
		Status:     "open",
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
	}
	ticketsMu.Lock()
	tickets[id] = t
	ticketsMu.Unlock()

	span.SetAttributes(
		attribute.String("ticket.id", id),
		attribute.String("ticket.severity", sev),
	)
	return map[string]any{
		"ticket_id":   id,
		"customer_id": t.CustomerID,
		"summary":     t.Summary,
		"severity":    t.Severity,
		"status":      t.Status,
		"created_at":  t.CreatedAt,
	}
}

func notifyHuman(ctx context.Context, args NotifyHumanArgs) map[string]any {
	ctx, span := tracer.Start(ctx, "notify_human")
	defer span.End()

	channel := args.Channel
	if channel == "" {
		channel = "slack"
	}
	ticketsMu.Lock()
	defer ticketsMu.Unlock()
	t, ok := tickets[args.TicketID]
	if !ok {
		return map[string]any{"error": "ticket not found", "ticket_id": args.TicketID}
	}
	span.SetAttributes(
		attribute.String("ticket.id", args.TicketID),
		attribute.String("notify.channel", channel),
	)
	t.Notifications = append(t.Notifications, map[string]string{
		"channel": channel,
		"at":      time.Now().UTC().Format(time.RFC3339),
	})
	return map[string]any{"ticket_id": args.TicketID, "notified": channel}
}

// ---------- ADK FunctionTool handlers ----------
//
// ADK is the source of truth for tool name, description, and the JSON schema
// inferred from these typed args/results. We don't run an ADK LlmAgent inside
// this process — these definitions are exposed to MCP — but they could be
// plugged into one without changing the core logic.

func createTicketADK(_ tool.Context, args CreateTicketArgs) (map[string]any, error) {
	return createTicket(context.Background(), args), nil
}

func notifyHumanADK(_ tool.Context, args NotifyHumanArgs) (map[string]any, error) {
	return notifyHuman(context.Background(), args), nil
}

// ---------- MCP wire handlers ----------

func createTicketMCP(ctx context.Context, _ *mcp.CallToolRequest, args CreateTicketArgs) (*mcp.CallToolResult, map[string]any, error) {
	return nil, createTicket(ctx, args), nil
}

func notifyHumanMCP(ctx context.Context, _ *mcp.CallToolRequest, args NotifyHumanArgs) (*mcp.CallToolResult, map[string]any, error) {
	return nil, notifyHuman(ctx, args), nil
}

// ---------- OTel setup ----------

func initTracing(ctx context.Context) (func(context.Context) error, error) {
	serviceName := os.Getenv("OTEL_SERVICE_NAME")
	if serviceName == "" {
		serviceName = "ticket-mcp"
	}
	exp, err := otlptracegrpc.New(ctx)
	if err != nil {
		return nil, err
	}
	res, err := sdkresource.New(ctx,
		sdkresource.WithAttributes(semconv.ServiceName(serviceName)),
	)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	return tp.Shutdown, nil
}

// ---------- main ----------

func main() {
	ctx := context.Background()

	shutdown, err := initTracing(ctx)
	if err != nil {
		log.Fatalf("init tracing: %v", err)
	}
	defer shutdown(ctx)

	createTool, err := functiontool.New(functiontool.Config{
		Name:        "create_ticket",
		Description: "Create an incident ticket. severity ∈ {low, medium, high, critical}.",
	}, createTicketADK)
	if err != nil {
		log.Fatalf("adk create_ticket: %v", err)
	}
	notifyTool, err := functiontool.New(functiontool.Config{
		Name:        "notify_human",
		Description: "Notify a human operator about a ticket. channel ∈ {slack, email, pager}.",
	}, notifyHumanADK)
	if err != nil {
		log.Fatalf("adk notify_human: %v", err)
	}
	// Keep references so the compiler doesn't complain — and so it's obvious
	// these ADK tools are part of the program even though MCP is the wire.
	_ = []tool.Tool{createTool, notifyTool}

	server := mcp.NewServer(&mcp.Implementation{Name: "ticket-mcp", Version: "1.0.0"}, nil)
	mcp.AddTool(server, &mcp.Tool{
		Name:        "create_ticket",
		Description: "Create an incident ticket. severity ∈ {low, medium, high, critical}.",
	}, createTicketMCP)
	mcp.AddTool(server, &mcp.Tool{
		Name:        "notify_human",
		Description: "Notify a human operator about a ticket. channel ∈ {slack, email, pager}.",
	}, notifyHumanMCP)

	handler := mcp.NewStreamableHTTPHandler(
		func(_ *http.Request) *mcp.Server { return server },
		&mcp.StreamableHTTPOptions{},
	)

	addr := ":8080"
	log.Printf("ticket-mcp listening on %s (Go ADK + MCP Go SDK)", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("http: %v", err)
	}
}
