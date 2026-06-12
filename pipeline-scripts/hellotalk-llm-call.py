#!/usr/bin/env python3
"""
Call an LLM API with automatic chunking, streaming, retry, quota
detection and prompt-cache reporting.

Usage:
  hellotalk-llm-call.py <prompt_file> <input_file> <output_file>
  hellotalk-llm-call.py --cache-probe <prompt_file> <input_file>

Exit codes:
  0  success
  1  ordinary failure (chunks failed / empty / network exhausted)
  2  quota / daily-limit hit — caller should abort the batch
  3  fatal (auth, bad request, model not found)

Behavior:
  * Streams responses (stream=True) so the connection stays warm during
    multi-minute reasoning phases and progress logs surface every 50
    reasoning chunks. An inter-chunk read timeout (STREAM_IDLE_TIMEOUT,
    default 240s) acts as a stall watchdog.
  * Retries 3x on transient network errors with [30,60,120]s backoff.
  * Detects quota / daily-limit responses across providers and writes a
    sentinel at $HELLOTALK_QUOTA_DIR/quota-block-<PROVIDER> with an
    auto-expiry (next 00:05 UTC for daily limits, +10 min for generic
    rate limits). Sentinel is checked by bash wrappers on next start.
  * Sends prompt as a system message (separate from user input) so
    automatic prefix caching on DeepSeek/Kimi-class models engages.
  * Logs prompt_tokens / cached-token usage when the provider returns it.

Inputs >120,000 chars are auto-chunked at blank-line / line boundaries
and joined with chunk headers (or plain when LLM_CHUNK_HEADERS=0, used
for TSV anki output).
"""
import sys, os, time, re, datetime, threading

MAX_RETRIES = 3
RETRY_DELAYS = [30, 60, 120]
STREAM_IDLE_TIMEOUT = float(os.environ.get("STREAM_IDLE_TIMEOUT", "240"))
CHUNK_THRESHOLD = 120000

QUOTA_DIR = os.path.expanduser(os.environ.get("HELLOTALK_QUOTA_DIR", "~/.cache/hellotalk"))


def log(msg):
    print(f"  {msg}", file=sys.stderr, flush=True)


# ──────────────────────────────────────────────────────────────────────
# Quota sentinel
# ──────────────────────────────────────────────────────────────────────

def _next_daily_reset_epoch():
    """Next 00:05 UTC after now."""
    now = datetime.datetime.now(datetime.timezone.utc)
    target = now.replace(hour=0, minute=5, second=0, microsecond=0)
    if target <= now:
        target += datetime.timedelta(days=1)
    return int(target.timestamp())


def write_quota_sentinel(reason, message):
    """reason: 'daily' or 'rate'."""
    try:
        os.makedirs(QUOTA_DIR, exist_ok=True)
        provider = os.environ.get("PROVIDER", "unknown")
        model = os.environ.get("MODEL", "unknown")
        if reason == "daily":
            expires_at = _next_daily_reset_epoch()
        else:
            expires_at = int(time.time()) + 600  # 10 minutes
        path = os.path.join(QUOTA_DIR, f"quota-block-{provider}")
        msg_clean = re.sub(r"\s+", " ", str(message))[:500]
        with open(path, "w") as f:
            f.write(f"provider={provider}\n")
            f.write(f"model={model}\n")
            f.write(f"hit_at={datetime.datetime.now(datetime.timezone.utc).isoformat()}\n")
            f.write(f"expires_at={expires_at}\n")
            f.write(f"reason={reason}\n")
            f.write(f"message={msg_clean}\n")
        until = datetime.datetime.fromtimestamp(expires_at, datetime.timezone.utc).isoformat()
        log(f"[QUOTA SENTINEL written: {path}, reason={reason}, clears at {until}]")
    except Exception as e:
        log(f"[WARN: failed to write quota sentinel: {e}]")


# ──────────────────────────────────────────────────────────────────────
# Error classification
# ──────────────────────────────────────────────────────────────────────

# Phrases that indicate a *daily* allowance has been used up.
DAILY_PATTERNS = [
    r"daily free allocation",
    r"daily\s+(quota|limit|allowance)",
    r"used up.*daily",
    r"neurons",                       # Cloudflare Workers AI
    r"limit exceeded for the day",
    r"配额.*(用完|耗尽|不足)",
    r"今日.*(额度|配额|限额)",
    r"日限额",
    r"daily token limit",
]

# Phrases that indicate quota/balance more generally (treat as daily-class abort).
QUOTA_PATTERNS = [
    r"insufficient[_\s-]?quota",
    r"quota.*(exhausted|exceeded|insufficient)",
    r"out of credits?",
    r"insufficient.*balance",
    r"余额不足",
    r"账户.*(欠费|余额)",
    r"billing",
    r"payment required",
]

DAILY_RE = re.compile("|".join(DAILY_PATTERNS), re.IGNORECASE)
QUOTA_RE = re.compile("|".join(QUOTA_PATTERNS), re.IGNORECASE)


def classify_error(exc):
    """Return ('transient'|'quota_daily'|'quota_rate'|'fatal', detail_str)."""
    import httpx

    # Network-level → transient
    if isinstance(exc, (httpx.TimeoutException, httpx.ConnectError,
                        httpx.RemoteProtocolError, ConnectionError, OSError)):
        return "transient", str(exc)

    status = getattr(exc, "status_code", None)
    body = ""
    # openai SDK: APIStatusError exposes .response and .message; .body sometimes set
    for attr in ("message", "body"):
        v = getattr(exc, attr, None)
        if v:
            body += " " + str(v)
    resp = getattr(exc, "response", None)
    if resp is not None:
        try:
            body += " " + resp.text
        except Exception:
            pass
    if not body:
        body = str(exc)

    # Quota / daily detection (substring first; status second)
    if DAILY_RE.search(body):
        return "quota_daily", body.strip()[:300]
    if QUOTA_RE.search(body):
        return "quota_daily", body.strip()[:300]

    if status == 402:
        return "quota_daily", body.strip()[:300]
    if status == 403 and re.search(r"quota|balance|credit|billing", body, re.IGNORECASE):
        return "quota_daily", body.strip()[:300]
    if status == 429:
        # Distinguish daily quota exhaustion (abort) from RPM rate-limit (retry)
        if DAILY_RE.search(body):
            return "quota_daily", body.strip()[:300]
        # Extract Retry-After from response headers if available
        retry_after = ""
        if resp is not None:
            ra = getattr(resp, "headers", {}).get("retry-after", "")
            if ra:
                retry_after = f" [retry-after={ra}s]"
        return "rate_limit", body.strip()[:300] + retry_after
    if status in (400, 401, 404, 422):
        return "fatal", f"HTTP {status}: {body.strip()[:300]}"
    if status and 500 <= status < 600:
        return "transient", f"HTTP {status}: {body.strip()[:300]}"

    # Unknown → treat as fatal so we don't silently burn through retries
    return "fatal", f"unclassified: {type(exc).__name__}: {body.strip()[:300]}"


class QuotaExceeded(Exception):
    def __init__(self, reason, detail):
        super().__init__(detail)
        self.reason = reason   # 'quota_daily' or 'quota_rate'
        self.detail = detail


class FatalAPIError(Exception):
    pass


# ──────────────────────────────────────────────────────────────────────
# Chunking
# ──────────────────────────────────────────────────────────────────────

def split_text(text, threshold):
    if len(text) <= threshold:
        return [text]

    def split_by_lines(block, limit):
        lines = block.split("\n")
        pieces = []
        current = []
        current_len = 0
        for line in lines:
            line_len = len(line) + 1
            if current and current_len + line_len > limit:
                pieces.append("\n".join(current))
                current = [line]
                current_len = line_len
            else:
                current.append(line)
                current_len += line_len
        if current:
            pieces.append("\n".join(current))
        return pieces

    sections = text.split("\n\n")
    coarse = []
    current = []
    current_len = 0
    for section in sections:
        section_len = len(section) + 2
        if current and current_len + section_len > threshold:
            coarse.append("\n\n".join(current))
            current = [section]
            current_len = section_len
        else:
            current.append(section)
            current_len += section_len
    if current:
        coarse.append("\n\n".join(current))

    chunks = []
    for chunk in coarse:
        if len(chunk) <= threshold:
            chunks.append(chunk)
        else:
            chunks.extend(split_by_lines(chunk, threshold))
    return chunks


def chunk_headers_enabled():
    value = os.environ.get("LLM_CHUNK_HEADERS", "1").strip().lower()
    return value not in {"0", "false", "no", "off"}


# ──────────────────────────────────────────────────────────────────────
# API client
# ──────────────────────────────────────────────────────────────────────

def api_key_for_base(base_url):
    explicit_key = os.environ.get("API_KEY")
    if explicit_key:
        return explicit_key
    if "nvidia.com" in base_url:
        return os.environ.get("NVIDIA_API_KEY", "")
    if "tencentmaas.com" in base_url or "tencent.com" in base_url:
        return os.environ.get("TENCENT_API_KEY", "")
    if "cloudflare.com" in base_url:
        return os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if "googleapis.com" in base_url:
        return os.environ.get("GOOGLE_API_KEY", "")
    return os.environ.get("NVIDIA_API_KEY", os.environ.get("CLOUDFLARE_API_TOKEN", ""))


def build_client():
    import httpx
    from openai import OpenAI

    base_url = os.environ.get("API_BASE", "https://integrate.api.nvidia.com/v1")
    # connect/write/pool kept tight; read = inter-chunk stall watchdog.
    timeout = httpx.Timeout(
        connect=30.0,
        read=STREAM_IDLE_TIMEOUT,
        write=30.0,
        pool=30.0,
    )
    client = OpenAI(
        base_url=base_url,
        api_key=api_key_for_base(base_url),
        timeout=timeout,
        max_retries=0,   # we handle retries ourselves
    )
    return client


_cached_client = None


def get_client():
    global _cached_client
    if _cached_client is None:
        _cached_client = build_client()
    return _cached_client


def _extract_usage(chunk):
    """Pull a usage dict off a stream chunk if present (last chunk for some providers)."""
    u = getattr(chunk, "usage", None)
    if u is None:
        return None
    try:
        return u.model_dump()
    except Exception:
        try:
            return dict(u)
        except Exception:
            return None


def call_api(system_prompt, input_chunk, return_usage=False):
    """Single streamed API call. Returns response text (and usage dict if requested)."""
    client = get_client()

    max_tokens_str = os.environ.get("MAX_TOKENS", "32768").strip()
    max_tokens = int(max_tokens_str) if max_tokens_str else 32768

    request = {
        "model": os.environ.get("MODEL", "moonshotai/kimi-k2.5"),
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user",   "content": input_chunk},
        ],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
    }

    reasoning_effort = os.environ.get("REASONING_EFFORT", "high")
    provider = os.environ.get("PROVIDER", "")
    if reasoning_effort and reasoning_effort.strip():
        request["reasoning_effort"] = reasoning_effort
        # Google's OpenAI-compat endpoint maps reasoning_effort natively
        # to thinking_level/thinking_budget — no extra_body needed.
        # Kimi/NVIDIA need the extra_body to enable thinking.
        if provider != "google":
            request["extra_body"] = {"thinking": {"type": "enabled"}}

    completion = client.chat.completions.create(**request)

    output_parts = []
    start = time.time()
    reasoning_chunks = 0
    usage = None

    for chunk in completion:
        u = _extract_usage(chunk)
        if u:
            usage = u
        if not getattr(chunk, "choices", None):
            continue
        delta = chunk.choices[0].delta
        reasoning = getattr(delta, "reasoning_content", None) or getattr(delta, "reasoning", None)
        if reasoning:
            reasoning_chunks += 1
            if reasoning_chunks % 1100 == 1:
                elapsed = int(time.time() - start)
                log(f"[thinking... {elapsed}s]")
        content = getattr(delta, "content", None)
        if content:
            output_parts.append(content)

    elapsed = int(time.time() - start)
    result = "".join(output_parts).lstrip()

    if usage:
        pt = usage.get("prompt_tokens")
        ct = usage.get("completion_tokens")
        # Try common cache-hit field names across providers
        cached = (usage.get("prompt_cache_hit_tokens")
                  or usage.get("cached_tokens")
                  or (usage.get("prompt_tokens_details") or {}).get("cached_tokens"))
        cache_str = f", cached={cached}" if cached is not None else ""
        log(f"[{elapsed}s, {len(result)} chars, prompt_tokens={pt}, completion_tokens={ct}{cache_str}]")
    else:
        log(f"[{elapsed}s, {len(result)} chars]")

    if return_usage:
        return result, usage
    return result


def _parse_retry_after(detail):
    """Extract retry-after seconds from error detail string."""
    m = re.search(r"\[retry-after=(\d+)s\]", detail)
    return int(m.group(1)) if m else 0


# Rate-limit retries use longer, separate backoff schedule
RATE_LIMIT_MAX_RETRIES = 8
RATE_LIMIT_BASE_DELAY = 60  # seconds; overridden by Retry-After if present


def call_with_retry(system_prompt, input_chunk, chunk_label=""):
    """Returns response text or None. Raises QuotaExceeded / FatalAPIError on those classes."""
    label = f" ({chunk_label})" if chunk_label else ""
    last_err = None
    transient_attempts = 0
    rate_limit_attempts = 0

    while True:
        try:
            result = call_api(system_prompt, input_chunk)
            if result.strip():
                return result
            last_err = "empty response"
            transient_attempts += 1
            log(f"[attempt {transient_attempts}/{MAX_RETRIES}{label}: empty response]")
            if transient_attempts >= MAX_RETRIES:
                break
            delay = RETRY_DELAYS[transient_attempts - 1]
            log(f"[retrying in {delay}s...]")
            time.sleep(delay)
        except Exception as e:
            kind, detail = classify_error(e)
            if kind == "quota_daily":
                log(f"[QUOTA{label}: {kind} — {detail}]")
                raise QuotaExceeded("daily", detail)
            if kind == "rate_limit":
                rate_limit_attempts += 1
                ra = _parse_retry_after(detail)
                delay = max(ra, RATE_LIMIT_BASE_DELAY)
                log(f"[RATE LIMIT{label}: attempt {rate_limit_attempts}/{RATE_LIMIT_MAX_RETRIES} — waiting {delay}s]")
                if rate_limit_attempts >= RATE_LIMIT_MAX_RETRIES:
                    log(f"[RATE LIMIT{label}: exhausted {RATE_LIMIT_MAX_RETRIES} retries]")
                    raise QuotaExceeded("rate", detail)
                time.sleep(delay)
                continue
            if kind == "fatal":
                log(f"[FATAL{label}: {detail}]")
                raise FatalAPIError(detail)
            # transient
            transient_attempts += 1
            last_err = detail
            log(f"[attempt {transient_attempts}/{MAX_RETRIES}{label} transient: {detail}]")
            if transient_attempts >= MAX_RETRIES:
                break
            delay = RETRY_DELAYS[transient_attempts - 1]
            log(f"[retrying in {delay}s...]")
            time.sleep(delay)

    log(f"[all {transient_attempts} transient attempts failed{label}: {last_err}]")
    return None


# ──────────────────────────────────────────────────────────────────────
# Cache probe
# ──────────────────────────────────────────────────────────────────────

def cache_probe(prompt_file, input_file):
    with open(prompt_file) as f:
        system_prompt = f.read()
    with open(input_file) as f:
        input_text = f.read()

    if len(input_text) > CHUNK_THRESHOLD:
        input_text = input_text[:CHUNK_THRESHOLD]
        log(f"[probe: input truncated to {CHUNK_THRESHOLD} chars]")

    provider = os.environ.get("PROVIDER", "?")
    model = os.environ.get("MODEL", "?")
    log(f"[CACHE PROBE] provider={provider} model={model}")
    log(f"[CACHE PROBE] system_prompt: {len(system_prompt)} chars / user: {len(input_text)} chars")

    results = []
    for n in (1, 2):
        log(f"[CACHE PROBE] call {n}/2 ...")
        try:
            text, usage = call_api(system_prompt, input_text, return_usage=True)
        except Exception as e:
            kind, detail = classify_error(e)
            log(f"[CACHE PROBE] call {n} failed ({kind}): {detail}")
            return 1
        if not usage:
            log(f"[CACHE PROBE] call {n}: provider returned no usage info — cannot verify caching")
            results.append(None)
        else:
            results.append(usage)

    print()
    print(f"=== Cache probe results: provider={provider} model={model} ===")
    for n, usage in enumerate(results, 1):
        if not usage:
            print(f"  call {n}: <no usage data>")
            continue
        pt = usage.get("prompt_tokens")
        ct = usage.get("completion_tokens")
        cached = (usage.get("prompt_cache_hit_tokens")
                  or usage.get("cached_tokens")
                  or (usage.get("prompt_tokens_details") or {}).get("cached_tokens"))
        miss = (usage.get("prompt_cache_miss_tokens"))
        print(f"  call {n}: prompt_tokens={pt} completion_tokens={ct} cached_tokens={cached} miss={miss}")
        print(f"           raw usage={usage}")

    if len(results) == 2 and all(results):
        c1 = (results[0].get("prompt_cache_hit_tokens")
              or results[0].get("cached_tokens")
              or (results[0].get("prompt_tokens_details") or {}).get("cached_tokens") or 0)
        c2 = (results[1].get("prompt_cache_hit_tokens")
              or results[1].get("cached_tokens")
              or (results[1].get("prompt_tokens_details") or {}).get("cached_tokens") or 0)
        print()
        if c2 > c1 and c2 > 0:
            print(f"  RESULT: caching ENGAGED — call 2 reports {c2} cached tokens (call 1: {c1}).")
        elif c1 == 0 and c2 == 0:
            print(f"  RESULT: caching NOT detected — both calls report 0 cached tokens.")
            print(f"          (Provider may not expose cache stats, or model does not support prefix cache.)")
        else:
            print(f"  RESULT: ambiguous — call 1 cached={c1}, call 2 cached={c2}")
    return 0


# ──────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    if args and args[0] == "--cache-probe":
        if len(args) != 3:
            print("Usage: hellotalk-llm-call.py --cache-probe <prompt_file> <input_file>", file=sys.stderr)
            sys.exit(2)
        sys.exit(cache_probe(args[1], args[2]))

    if len(args) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    prompt_file, input_file, output_path = args

    with open(prompt_file) as f:
        system_prompt = f.read()
    with open(input_file) as f:
        input_text = f.read()

    chunks = split_text(input_text, CHUNK_THRESHOLD)
    total = len(chunks)
    use_chunk_headers = chunk_headers_enabled()

    if total == 1:
        log(f"[single request: {len(input_text)} chars]")
        try:
            result = call_with_retry(system_prompt, input_text)
        except QuotaExceeded as q:
            write_quota_sentinel("daily" if q.reason == "daily" else "rate", q.detail)
            sys.exit(2)
        except FatalAPIError:
            sys.exit(3)
        if not result:
            sys.exit(1)
        with open(output_path, "w") as f:
            f.write(result)
        sys.exit(0)

    log(f"[splitting into {total} chunks]")
    results = []
    chunk_failed = 0

    for idx, chunk in enumerate(chunks, 1):
        label = f"chunk {idx}/{total}"
        log(f"[{label}: {len(chunk)} chars]")
        try:
            result = call_with_retry(system_prompt, chunk, label)
        except QuotaExceeded as q:
            write_quota_sentinel("daily" if q.reason == "daily" else "rate", q.detail)
            log(f"[QUOTA — aborting remaining {total - idx} chunk(s)]")
            sys.exit(2)
        except FatalAPIError:
            sys.exit(3)

        if result:
            if use_chunk_headers:
                results.append(f"--- Chunk {idx}/{total} ---\n\n{result}")
            else:
                results.append(result.rstrip("\n"))
        else:
            chunk_failed += 1
            if use_chunk_headers:
                results.append(f"--- Chunk {idx}/{total} ---\n\n[ANALYSIS FAILED — will retry on next run]\n")
            else:
                results.append("[ANALYSIS FAILED — will retry on next run]")

    combined = "\n\n".join(results) if use_chunk_headers else "\n".join(results)
    with open(output_path, "w") as f:
        f.write(combined)

    if chunk_failed > 0:
        log(f"[WARNING: {chunk_failed}/{total} chunks failed]")
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
