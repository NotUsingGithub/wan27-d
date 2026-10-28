/**
 * Server-side D client for https://wan2-7.io/api/v1/.
 *
 * Documentation:
 * - Website: https://wan2-7.io/
 * - MCP Server: https://wan2-7.io/mcp/
 * - MCP & API Guide: https://wan2-7.io/mcp/guide/
 * - CLI Reference: https://wan2-7.io/cli/
 * - Pricing: https://wan2-7.io/pricing/
 */
module wan27.client;

import std.algorithm.searching : canFind, endsWith;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : strip, split;

/// Canonical Wan27 service and documentation URLs.
enum Wan27Urls : string
{
    website  = "https://wan2-7.io/",
    mcp      = "https://wan2-7.io/mcp/",
    mcpGuide = "https://wan2-7.io/mcp/guide/",
    cli      = "https://wan2-7.io/cli/",
    pricing  = "https://wan2-7.io/pricing/",
    apiBase  = "https://wan2-7.io/api/v1/"
}

/// Exception thrown by Wan27 client operations with a stable error code and optional HTTP status.
class Wan27Exception : Exception
{
    string code;
    int status;

    this(string code, string msg, int status = 0, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.code = code;
        this.status = status;
    }
}

/// Outbound HTTP request descriptor produced by Wan27Client.
struct Wan27Request
{
    string method;
    string url;
    string[string] headers;
    string bodyText;
    uint timeoutSeconds;
}

/// Raw HTTP response returned by a transport delegate.
struct Wan27RawResponse
{
    int status;
    string bodyText;
}

alias Wan27Transport = Wan27RawResponse delegate(Wan27Request req);

/// Validate a URL path segment (model ID or task ID).
string validateSegment(string value) @safe pure
{
    if (value.length == 0 || value == "." || value == "..")
    {
        throw new Wan27Exception("INVALID_INPUT", "Provide a nonempty model or task ID.");
    }
    foreach (char c; value)
    {
        if (c < 0x20 || c == '/' || c == '\\' || c == '?' || c == '#')
        {
            throw new Wan27Exception("INVALID_INPUT", "Segment contains disallowed control or path characters.");
        }
    }
    return value;
}

/// Validate an idempotency request ID (16-128 alphanumeric, underscore, or hyphen characters).
string validateRequestId(string requestId) @safe pure
{
    if (requestId.length < 16 || requestId.length > 128)
    {
        throw new Wan27Exception(
            "INVALID_INPUT",
            "requestId must be 16-128 letters, digits, underscores or hyphens."
        );
    }
    foreach (char c; requestId)
    {
        if (!(isAlphaNum(c) || c == '_' || c == '-'))
        {
            throw new Wan27Exception(
                "INVALID_INPUT",
                "requestId must contain only ASCII letters, digits, underscores or hyphens."
            );
        }
    }
    return requestId;
}

/**
 * Client for https://wan2-7.io/api/v1/.
 *
 * Supply an existing access token from your server-side secret store.
 * API access requires an active paid subscription (https://wan2-7.io/pricing/)
 * and generation consumes credits.
 */
class Wan27Client
{
    private string _token;
    private uint _timeoutSeconds;
    private Wan27Transport _transport;

    this(string token, uint timeoutSeconds = 120, Wan27Transport transport = null)
    {
        string trimmed = token.strip();
        if (trimmed.length == 0 || token.canFind('\r') || token.canFind('\n'))
        {
            throw new Wan27Exception("AUTH_REQUIRED", "Provide an existing Wan27 access token.");
        }
        if (timeoutSeconds == 0 || timeoutSeconds > 120)
        {
            throw new Wan27Exception("INVALID_INPUT", "timeoutSeconds must be between 1 and 120.");
        }
        this._token = token;
        this._timeoutSeconds = timeoutSeconds;
        this._transport = transport;
    }

    /// Build a canonical Wan27Request for any API route.
    Wan27Request buildRequest(string method, string path, JSONValue* payload = null, string requestId = null)
    {
        string bodyStr = "";
        if (payload !is null)
        {
            if (payload.type != JSONType.object)
            {
                throw new Wan27Exception("INVALID_INPUT", "Input must be a JSON object.");
            }
            bodyStr = payload.toString();
            if (bodyStr.length > 32_768)
            {
                throw new Wan27Exception("INVALID_INPUT", "Request exceeds 32 KiB.");
            }
        }

        auto qParts = path.split("?");
        string route = qParts[0];
        string query = qParts.length > 1 ? qParts[1] : "";
        if (!route.endsWith("/"))
        {
            route ~= "/";
        }
        string fullUrl = Wan27Urls.apiBase ~ route ~ (query.length > 0 ? "?" ~ query : "");

        string[string] headers;
        headers["Authorization"] = "Bearer " ~ _token;
        headers["Accept"] = "application/json";
        headers["X-Wan27-Client-Mode"] = "cli";
        if (payload !is null)
        {
            headers["Content-Type"] = "application/json";
        }
        if (requestId.length > 0)
        {
            headers["Idempotency-Key"] = requestId;
        }

        return Wan27Request(method, fullUrl, headers, bodyStr, _timeoutSeconds);
    }

    /// Execute a request through the configured transport or std.net.curl.
    JSONValue call(string method, string path, JSONValue* payload = null, string requestId = null)
    {
        auto req = buildRequest(method, path, payload, requestId);
        Wan27RawResponse raw;
        if (_transport !is null)
        {
            raw = _transport(req);
        }
        else
        {
            throw new Wan27Exception(
                "TRANSPORT_REQUIRED",
                "Provide a Wan27Transport delegate (such as std.net.curl HTTP) for live network calls."
            );
        }

        if (raw.status >= 300 && raw.status < 400)
        {
            throw new Wan27Exception("REDIRECT_REJECTED", "API redirects are not followed.", raw.status);
        }
        if (raw.bodyText.length > 2_097_152)
        {
            throw new Wan27Exception("INVALID_RESPONSE", "Oversized API response.", raw.status);
        }

        JSONValue data;
        if (raw.status == 204 && raw.bodyText.strip().length == 0)
        {
            data = parseJSON("{}");
        }
        else
        {
            try
            {
                data = parseJSON(raw.bodyText.length > 0 ? raw.bodyText : "{}");
            }
            catch (Exception)
            {
                throw new Wan27Exception("INVALID_RESPONSE", "Unreadable JSON response.", raw.status);
            }
            if (data.type != JSONType.object)
            {
                throw new Wan27Exception("INVALID_RESPONSE", "Expected JSON object response.", raw.status);
            }
        }

        if (raw.status < 200 || raw.status >= 300)
        {
            string errCode = "API_ERROR";
            string errMsg = "Wan27 returned HTTP " ~ raw.status.to!string ~ ".";
            if ("error" in data && data["error"].type == JSONType.object)
            {
                auto errObj = data["error"];
                if ("code" in errObj && errObj["code"].type == JSONType.string)
                    errCode = errObj["code"].str;
                if ("message" in errObj && errObj["message"].type == JSONType.string)
                    errMsg = errObj["message"].str;
            }
            throw new Wan27Exception(errCode, errMsg, raw.status);
        }
        return data;
    }

    /// Read account eligibility and credit balance.
    JSONValue account()
    {
        return call("GET", "account");
    }

    /// List currently supported models.
    JSONValue models()
    {
        return call("GET", "models");
    }

    /// Read input schema for a specific model.
    JSONValue model(string modelId)
    {
        return call("GET", "models/" ~ validateSegment(modelId));
    }

    /// Estimate credit cost without creating a paid task.
    JSONValue estimate(JSONValue input)
    {
        return call("POST", "estimates", &input);
    }

    /// Create an authorized paid generation with an explicit idempotency requestId.
    JSONValue generate(JSONValue input, string requestId)
    {
        validateRequestId(requestId);
        return call("POST", "generations", &input, requestId);
    }

    /// List recent tasks (limit 1..50).
    JSONValue tasks(uint limit = 20, string cursor = null)
    {
        if (limit < 1 || limit > 50)
        {
            throw new Wan27Exception("INVALID_INPUT", "limit must be between 1 and 50.");
        }
        string q = "limit=" ~ limit.to!string;
        if (cursor.length > 0)
        {
            q ~= "&cursor=" ~ validateSegment(cursor);
        }
        return call("GET", "tasks?" ~ q);
    }

    /// Retrieve task state and output URLs by task ID.
    JSONValue task(string taskId)
    {
        return call("GET", "tasks/" ~ validateSegment(taskId));
    }
}

unittest
{
    assert(Wan27Urls.website == "https://wan2-7.io/");
    assert(Wan27Urls.mcp == "https://wan2-7.io/mcp/");
    assert(Wan27Urls.mcpGuide == "https://wan2-7.io/mcp/guide/");
    assert(Wan27Urls.cli == "https://wan2-7.io/cli/");
    assert(Wan27Urls.pricing == "https://wan2-7.io/pricing/");

    Wan27Request lastReq;
    auto client = new Wan27Client("wan27_d_test_token", 60, (Wan27Request req) {
        lastReq = req;
        return Wan27RawResponse(200, `{"id":"task_d_001","status":"queued"}`);
    });

    auto acc = client.account();
    assert(lastReq.method == "GET");
    assert(lastReq.url == "https://wan2-7.io/api/v1/account/");
    assert(lastReq.headers["Authorization"] == "Bearer wan27_d_test_token");

    JSONValue payload = parseJSON(`{"modelId":"wan27-text-to-video","prompt":"Ocean waves at sunrise"}`);
    auto gen = client.generate(payload, "req_dlang_20261028_0001");
    assert(gen["id"].str == "task_d_001");
    assert(lastReq.method == "POST");
    assert(lastReq.url == "https://wan2-7.io/api/v1/generations/");
    assert(lastReq.headers["Idempotency-Key"] == "req_dlang_20261028_0001");
}
