"""
Shared environment bootstrap for all REPOS programs.

Usage — add this as first import in every entrypoint:

    from python_header import env, get, get_int, get_port

How it works:
  1. Loads config.conf from the calling script's directory
  2. Loads auxiliary *.env files, then .env; falls back to env.example if none exist
  3. Injected process env wins over file values
  4. If FASTAPI_HOST was injected by the process, the web server binds 0.0.0.0
  5. All values are accessible via env dict, get(), or os.environ

Requires: pip install python-dotenv
"""

import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from dotenv import dotenv_values

_process_env = dict(os.environ)
_process_env_has_fastapi_host = "FASTAPI_HOST" in _process_env


def _normalize_env_value(value: str | None) -> str:
    value = "" if value is None else str(value)
    if value.strip().lower() == "blank":
        return ""
    return value


def _find_project_dir() -> Path:
    """Walk the call stack to find the project directory."""
    import inspect
    for frame_info in inspect.stack():
        caller_file = frame_info.filename
        if caller_file and not caller_file.startswith("<"):
            directory = Path(caller_file).resolve().parent
            if (directory / "config.conf").exists() or (directory / "config.conf_example").exists() or (directory / ".env").exists():
                return directory
    return Path.cwd()


def _apply_values(values: dict[str, str], overwrite: bool) -> None:
    for key, value in values.items():
        if not key:
            continue
        if overwrite or key not in os.environ:
            os.environ[key] = _normalize_env_value(value)


def _read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for key, value in dotenv_values(path).items():
        values[key] = _normalize_env_value(value)
    return values


def _read_env_files(env_dir: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    files = sorted(p for p in env_dir.glob("*.env") if p.name != ".env")
    dot_env = env_dir / ".env"
    if dot_env.exists():
        files.append(dot_env)
    if not files:
        env_example = env_dir / "env.example"
        if env_example.exists():
            files.append(env_example)
    for path in files:
        values.update(_read_env_file(path))
    return values


_env_dir = _find_project_dir()
_config_file = _env_dir / "config.conf"
if not _config_file.exists():
    _config_file = _env_dir / "config.conf_example"
_config_values = _read_env_file(_config_file)
_file_values = dict(_config_values)
_file_values.update(_read_env_files(_env_dir))
_apply_values(_file_values, overwrite=False)

_apply_values(_process_env, overwrite=True)

if _process_env_has_fastapi_host:
    os.environ["FASTAPI_HOST"] = "0.0.0.0"


def _ensure_local_sqlite_dir() -> None:
    backend_pattern = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*_DB_BACKEND)\s*=\s*([^#]*)")
    backends: dict[str, str] = {}
    for example in sorted(_env_dir.glob("env*example")):
        for line in example.read_text(encoding="utf-8").splitlines():
            if line.lstrip().startswith("#"):
                continue
            match = backend_pattern.match(line)
            if match:
                backends.setdefault(match.group(1), _normalize_env_value(match.group(2)).strip())

    for key, default in backends.items():
        if os.environ.get(key, default).strip().lower() in {"sqlite", "sqlite3"}:
            (_env_dir / "sqlite").mkdir(parents=True, exist_ok=True)
            return


_ensure_local_sqlite_dir()


def get(key: str, default: str = "") -> str:
    """Get env var as string."""
    return os.environ.get(key, default).strip()


def get_int(key: str, default: int = 0) -> int:
    """Get env var as int, fallback to default on bad input."""
    raw = os.environ.get(key, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except (ValueError, TypeError):
        return default


def get_bool(key: str, default: bool = False) -> bool:
    """Get env var as bool (1/true/yes/on → True)."""
    raw = os.environ.get(key, "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


def get_port(key: str, default: int = 8080) -> int:
    """Get env var as validated port number (1-65535)."""
    port = get_int(key, default)
    if not (1 <= port <= 65535):
        raise ValueError(f"{key}={port} is not a valid port (1-65535)")
    return port


@dataclass(frozen=True)
class OpenAIV1Provider:
    index: int
    suffix: str
    env_prefix: str
    provider: str
    base_url: str
    api_key: str

    @property
    def key(self) -> str:
        return "openai_v1" if self.index == 1 else f"openai_v1_{self.index}"

    @property
    def label(self) -> str:
        return "OpenAI v1" if self.index == 1 else f"OpenAI v1 #{self.index}"


def _clean_openai_v1(value: str | None) -> str:
    return (value or "").strip().strip('"').strip("'")


def _normalize_openai_v1_base_url(raw_url: str, raw_port: str = "") -> str:
    url = _clean_openai_v1(raw_url).rstrip("/")
    port = _clean_openai_v1(raw_port)
    if not url:
        return ""
    if "://" not in url:
        url = f"http://{url}"

    parsed = urlsplit(url)
    try:
        has_port = parsed.port is not None
    except ValueError:
        has_port = False

    netloc = parsed.netloc
    if port and not has_port:
        netloc = f"{netloc}:{port}"

    path = parsed.path.rstrip("/")
    base = urlunsplit((parsed.scheme, netloc, path, "", "")).rstrip("/")
    return base if path else f"{base}/v1"


def _openai_v1_suffixes(values: dict[str, str]) -> list[tuple[int, str]]:
    indexes = {1}
    pattern = re.compile(r"^OPENAI_V1_(?:PROVIDER|URL|PORT|KEY)_(\d+)$")
    for key in values:
        match = pattern.match(key)
        if match:
            indexes.add(int(match.group(1)))
    return [(index, "" if index == 1 else f"_{index}") for index in sorted(indexes)]


def _openai_v1_value(source: dict[str, str], field: str, index: int) -> str:
    if index == 1:
        return source.get(f"OPENAI_V1_{field}", "")
    for suffix in (f"_{index}", f"_{index:02d}"):
        value = source.get(f"OPENAI_V1_{field}{suffix}", "")
        if value:
            return value
    pattern = re.compile(rf"^OPENAI_V1_{re.escape(field)}_(\d+)$")
    for key in sorted(source):
        match = pattern.match(key)
        if match and int(match.group(1)) == index:
            return source.get(key, "")
    return ""


def openai_v1_providers(values: dict[str, str] | None = None) -> list[OpenAIV1Provider]:
    source = dict(os.environ) if values is None else values
    providers: list[OpenAIV1Provider] = []
    for index, suffix in _openai_v1_suffixes(source):
        base_url = _normalize_openai_v1_base_url(
            _openai_v1_value(source, "URL", index),
            _openai_v1_value(source, "PORT", index),
        )
        if not base_url:
            continue
        providers.append(
            OpenAIV1Provider(
                index=index,
                suffix=suffix,
                env_prefix=f"OPENAI_V1{suffix}",
                provider=_clean_openai_v1(_openai_v1_value(source, "PROVIDER", index)),
                base_url=base_url,
                api_key=_clean_openai_v1(_openai_v1_value(source, "KEY", index)),
            )
        )
    return providers


def openai_v1_first_provider(values: dict[str, str] | None = None) -> OpenAIV1Provider | None:
    providers = openai_v1_providers(values)
    return providers[0] if providers else None


def openai_v1_client(provider: OpenAIV1Provider | None = None, *, timeout: float = 60.0):
    provider = provider or openai_v1_first_provider()
    if provider is None:
        raise RuntimeError("OPENAI_V1_URL is not configured.")
    try:
        from openai import OpenAI
    except ImportError as exc:
        raise RuntimeError("Python package 'openai' is required for OpenAI v1 calls.") from exc
    return OpenAI(api_key=provider.api_key or "not-needed", base_url=provider.base_url, timeout=timeout)


def openai_v1_async_client(provider: OpenAIV1Provider | None = None, *, timeout: float = 60.0):
    provider = provider or openai_v1_first_provider()
    if provider is None:
        raise RuntimeError("OPENAI_V1_URL is not configured.")
    try:
        from openai import AsyncOpenAI
    except ImportError as exc:
        raise RuntimeError("Python package 'openai' is required for OpenAI v1 calls.") from exc
    return AsyncOpenAI(api_key=provider.api_key or "not-needed", base_url=provider.base_url, timeout=timeout)


def openai_v1_models(provider: OpenAIV1Provider | None = None, *, timeout: float = 10.0) -> list[str]:
    client = openai_v1_client(provider, timeout=timeout)
    response = client.models.list()
    return sorted({model.id for model in response.data if getattr(model, "id", "")})


def openai_v1_provider_models(
    values: dict[str, str] | None = None,
    *,
    timeout: float = 10.0,
) -> dict[OpenAIV1Provider, list[str]]:
    result: dict[OpenAIV1Provider, list[str]] = {}
    for provider in openai_v1_providers(values):
        result[provider] = openai_v1_models(provider, timeout=timeout)
    return result


def openai_v1_provider_for_model(
    model: str,
    values: dict[str, str] | None = None,
    *,
    timeout: float = 10.0,
) -> OpenAIV1Provider | None:
    providers = openai_v1_providers(values)
    if not providers:
        return None
    if len(providers) == 1:
        return providers[0]

    wanted = (model or "").strip()
    for provider in providers:
        try:
            if wanted in openai_v1_models(provider, timeout=timeout):
                return provider
        except Exception:
            continue
    return providers[0]


# Snapshot for dict-style access: env["KEY"] or env.get("KEY", "default")
env = dict(os.environ)
