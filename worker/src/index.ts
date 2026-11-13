/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Anthropic, OpenAI, ElevenLabs, and AssemblyAI APIs so the app
 * never ships with raw API keys. Keys are stored as Cloudflare secrets or passed by
 * BYOK clients when self-hosting.
 *
 * Routes:
 *   GET  /healthz                     → Worker health check
 *   POST /chat                        → Anthropic Messages API (streaming)
 *   POST /tts                         → ElevenLabs TTS API
 *   POST /transcribe-token            → AssemblyAI v3 streaming token
 *   POST /v1/responses                → OpenAI Responses API (streaming)
 *   POST /agent/openai/v1/responses   → OpenAI Responses API for clicky-harness
 *   POST /agent/anthropic/v1/messages → Anthropic Messages API for clicky-harness
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  OPENAI_API_KEY?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    try {
      if (url.pathname === "/healthz") {
        if (request.method !== "GET") {
          return jsonResponse({ error: "Method not allowed" }, 405);
        }
        return jsonResponse({ status: "ok", service: "clicky-worker" }, 200);
      }

      if (request.method !== "POST") {
        return jsonResponse({ error: "Method not allowed" }, 405);
      }

      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }

      if (
        url.pathname === "/v1/responses" ||
        url.pathname === "/agent/openai/v1/responses"
      ) {
        return await handleOpenAIResponses(request, env, url.pathname);
      }

      if (url.pathname === "/agent/anthropic/v1/messages") {
        return await handleAgentAnthropicMessages(request, env);
      }

      return jsonResponse({ error: "Not found" }, 404);
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonResponse(
        { error: error instanceof Error ? error.message : String(error) },
        500
      );
    }
  },
};

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function extractBearerToken(headerValue: string | null): string | undefined {
  if (!headerValue) {
    return undefined;
  }
  const trimmed = headerValue.trim();
  if (!trimmed) {
    return undefined;
  }
  const match = trimmed.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return undefined;
  }
  const token = match[1].trim();
  return token || undefined;
}

async function buildUpstreamErrorResponse(
  routeLabel: string,
  response: Response,
  upstreamName: string
): Promise<Response> {
  const errorBody = await response.text();
  console.error(`[${routeLabel}] ${upstreamName} API error ${response.status}: ${errorBody}`);

  const trimmed = errorBody.trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      JSON.parse(trimmed);
      return new Response(trimmed, {
        status: response.status,
        headers: { "content-type": "application/json" },
      });
    } catch {
      // Wrap non-JSON upstream error bodies cleanly below.
    }
  }

  return jsonResponse(
    {
      error: trimmed || `${upstreamName} API error (${response.status})`,
      status: response.status,
    },
    response.status
  );
}

function buildStreamingPassthroughResponse(response: Response): Response {
  const contentType = response.headers.get("content-type") || "text/event-stream";
  const headers: Record<string, string> = {
    "content-type": contentType,
    "cache-control": "no-cache",
  };
  if (contentType.toLowerCase().includes("text/event-stream")) {
    headers["x-accel-buffering"] = "no";
  }

  return new Response(response.body, {
    status: response.status,
    headers,
  });
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const clientApiKey = request.headers.get("x-api-key") || env.ANTHROPIC_API_KEY;

  if (!clientApiKey) {
    return jsonResponse(
      { error: "Missing Anthropic API key in header or worker env" },
      401
    );
  }

  const upstreamHeaders: Record<string, string> = {
    "x-api-key": clientApiKey,
    "anthropic-version": request.headers.get("anthropic-version") || "2023-06-01",
    "content-type": "application/json",
  };
  const anthropicBeta = request.headers.get("anthropic-beta");
  if (anthropicBeta) {
    upstreamHeaders["anthropic-beta"] = anthropicBeta;
  }

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: upstreamHeaders,
    body,
  });

  if (!response.ok) {
    return await buildUpstreamErrorResponse("/chat", response, "Anthropic");
  }

  return buildStreamingPassthroughResponse(response);
}

async function handleAgentAnthropicMessages(
  request: Request,
  env: Env
): Promise<Response> {
  const body = await request.text();
  const headerApiKey = request.headers.get("x-api-key")?.trim();
  const bearerApiKey = extractBearerToken(request.headers.get("authorization"));
  const clientApiKey = headerApiKey || bearerApiKey || env.ANTHROPIC_API_KEY;

  if (!clientApiKey) {
    return jsonResponse(
      { error: "Missing Anthropic API key in header or worker env" },
      401
    );
  }

  const upstreamHeaders: Record<string, string> = {
    "x-api-key": clientApiKey,
    "anthropic-version": request.headers.get("anthropic-version") || "2023-06-01",
    "content-type": request.headers.get("content-type") || "application/json",
  };
  const anthropicBeta = request.headers.get("anthropic-beta");
  if (anthropicBeta) {
    upstreamHeaders["anthropic-beta"] = anthropicBeta;
  }
  const accept = request.headers.get("accept");
  if (accept) {
    upstreamHeaders["accept"] = accept;
  }

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: upstreamHeaders,
    body,
  });

  if (!response.ok) {
    return await buildUpstreamErrorResponse(
      "/agent/anthropic/v1/messages",
      response,
      "Anthropic"
    );
  }

  return buildStreamingPassthroughResponse(response);
}

async function handleOpenAIResponses(
  request: Request,
  env: Env,
  routeLabel: string
): Promise<Response> {
  const body = await request.text();
  const clientBearer = extractBearerToken(request.headers.get("authorization"));
  const apiKey = clientBearer || env.OPENAI_API_KEY;

  if (!apiKey) {
    return jsonResponse(
      { error: "Missing OpenAI API key in Authorization header or worker env" },
      401
    );
  }

  const upstreamHeaders: Record<string, string> = {
    authorization: `Bearer ${apiKey}`,
    "content-type": request.headers.get("content-type") || "application/json",
  };
  const accept = request.headers.get("accept");
  if (accept) {
    upstreamHeaders["accept"] = accept;
  }
  const openAIBeta = request.headers.get("openai-beta");
  if (openAIBeta) {
    upstreamHeaders["openai-beta"] = openAIBeta;
  }

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: upstreamHeaders,
    body,
  });

  if (!response.ok) {
    return await buildUpstreamErrorResponse(routeLabel, response, "OpenAI");
  }

  return buildStreamingPassthroughResponse(response);
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    return await buildUpstreamErrorResponse("/transcribe-token", response, "AssemblyAI");
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const clientApiKey = request.headers.get("xi-api-key") || env.ELEVENLABS_API_KEY;
  const voiceId = request.headers.get("x-voice-id") || env.ELEVENLABS_VOICE_ID || "kPzsL2i3teMYv0FxEYQ6";

  if (!clientApiKey) {
    return jsonResponse(
      { error: "Missing ElevenLabs API key in header or worker env" },
      401
    );
  }

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": clientApiKey,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    return await buildUpstreamErrorResponse("/tts", response, "ElevenLabs");
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
