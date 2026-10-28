# wan27 — D Language Client for Wan27 AI Image & Video Generation

A lightweight, dependency-free D client for [Wan27](https://wan2-7.io/), an AI image and video generation service and [MCP workflow ecosystem](https://wan2-7.io/mcp/). Inspect account eligibility, query model schemas, estimate credit costs, submit idempotent generation tasks, and poll task results from D server applications.

**The D library is MIT licensed. Calling the hosted API requires an active paid [Wan27 subscription](https://wan2-7.io/pricing/), and generation spends credits.** A credit pack alone does not enable API access.

## Installation (DUB)

Add `wan27` to your `dub.json`:

```json
{
  "dependencies": {
    "wan27": "~>0.1.0"
  }
}
```

Or fetch via DUB CLI:

```sh
dub add wan27
```

## Usage

```d
import std.json : parseJSON;
import std.stdio : writeln;
import wan27;

void main()
{
    writeln("Wan27 Website: ", Wan27Urls.website);
    writeln("Wan27 MCP Guide: ", Wan27Urls.mcpGuide);

    // Supply an existing token from your server secret store and a transport delegate
    auto client = new Wan27Client("wan27_example_token", 120, (Wan27Request req) {
        // Plug in std.net.curl or vibe.d HTTP client here
        return Wan27RawResponse(200, `{"id":"task_01","status":"queued"}`);
    });

    auto input = parseJSON(`{
        "modelId": "wan27-text-to-video",
        "prompt": "A paper boat drifting through a rain puddle, gentle tracking shot",
        "durationSeconds": 5,
        "resolution": "720p"
    }`);

    // Estimate before spending credits
    writeln(client.estimate(input));

    // Persist a 16-128 char idempotency requestId before calling generate()
    auto task = client.generate(input, "req_20261028_paper_boat_0001");
    writeln("Created task ID: ", task["id"].str);
}
```

## Safety & Idempotency Guidelines

- **No automatic paid retries:** Always persist `requestId` before calling `client.generate()`. If a network timeout occurs, inspect `client.tasks()` and reuse the same `requestId` for any retry.
- **Server-side credentials:** Use the [Wan27 CLI](https://wan2-7.io/cli/) for interactive authentication and media uploads, or inject `WAN27_ACCESS_TOKEN` in your server environment. Never embed tokens in public repositories.
- **Strict transport:** Requests target `https://wan2-7.io/api/v1/` over HTTPS, enforce a 120-second maximum timeout, and reject HTTP redirects.

## Links & Documentation

- [Wan27 Official Website](https://wan2-7.io/)
- [Wan27 MCP Server](https://wan2-7.io/mcp/)
- [Wan27 MCP and API Workflow Guide](https://wan2-7.io/mcp/guide/)
- [Wan27 CLI Documentation](https://wan2-7.io/cli/)
- [Wan27 Pricing & Plans](https://wan2-7.io/pricing/)
- [GitHub Repository](https://github.com/NotUsingGithub/wan27-d)
