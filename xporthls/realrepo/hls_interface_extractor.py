from __future__ import annotations

import argparse
import json
import re
import shlex
from collections import Counter, defaultdict
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SOURCE_EXTENSIONS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx"}
EXCLUDED_DIRS = {".git", "__pycache__"}


@dataclass
class IncludeEdge:
    file: str
    line: int
    include: str
    kind: str


@dataclass
class HlsPragma:
    file: str
    line: int
    raw: str
    directive: str
    interface_type: str | None = None
    options: dict[str, str] = field(default_factory=dict)


@dataclass
class FunctionArgument:
    raw: str
    name: str | None
    type: str
    pointer: bool = False
    reference: bool = False
    array: bool = False


@dataclass
class HlsFunction:
    file: str
    name: str
    line_start: int
    line_end: int
    return_type: str
    args: list[FunctionArgument] = field(default_factory=list)
    extern_c: bool = False
    pragmas: list[HlsPragma] = field(default_factory=list)
    includes: list[str] = field(default_factory=list)
    has_dataflow: bool = False
    hls_stream_markers: int = 0
    is_kernel_candidate: bool = False
    candidate_reasons: list[str] = field(default_factory=list)


@dataclass
class HlsFileIR:
    path: str
    includes: list[IncludeEdge] = field(default_factory=list)
    pragmas: list[HlsPragma] = field(default_factory=list)
    functions: list[HlsFunction] = field(default_factory=list)
    markers: dict[str, int] = field(default_factory=dict)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json_optional(path: str | None) -> dict[str, Any] | None:
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        return None
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def read_text(path: Path, max_bytes: int = 5_000_000) -> str:
    try:
        if path.stat().st_size > max_bytes:
            return ""
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def rel_path(root: Path, path: Path) -> str:
    return str(path.resolve().relative_to(root.resolve()))


def unique_sorted(items: list[str]) -> list[str]:
    return sorted({x for x in items if x})


def strip_comments_for_matching(text: str) -> str:
    # Preserve line structure for line number stability.
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r"//.*", "", text)
    return text


def count_markers(text: str) -> dict[str, int]:
    patterns = {
        "hls_pragmas": r"#\s*pragma\s+HLS",
        "interface_pragmas": r"#\s*pragma\s+HLS\s+INTERFACE",
        "m_axi": r"#\s*pragma\s+HLS\s+INTERFACE\s+m_axi|interface\s+m_axi",
        "axis": r"#\s*pragma\s+HLS\s+INTERFACE\s+axis|interface\s+axis",
        "s_axilite": r"#\s*pragma\s+HLS\s+INTERFACE\s+s_axilite|interface\s+s_axilite",
        "dataflow": r"#\s*pragma\s+HLS\s+DATAFLOW",
        "pipeline": r"#\s*pragma\s+HLS\s+PIPELINE",
        "unroll": r"#\s*pragma\s+HLS\s+UNROLL",
        "hls_stream": r"\bhls::stream\b",
        "extern_c": r"extern\s+\"C\"",
        "ap_uint": r"\bap_uint\s*<",
        "ap_int": r"\bap_int\s*<",
    }

    return {key: len(re.findall(pattern, text, flags=re.I)) for key, pattern in patterns.items()}


def parse_includes(text: str, file_rel: str) -> list[IncludeEdge]:
    includes: list[IncludeEdge] = []
    pattern = re.compile(r'^\s*#\s*include\s*([<"])([^>"]+)[>"]', re.M)

    for match in pattern.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        kind = "system" if match.group(1) == "<" else "local"
        includes.append(
            IncludeEdge(
                file=file_rel,
                line=line,
                include=match.group(2),
                kind=kind,
            )
        )

    return includes


def parse_pragma_options(tokens: list[str]) -> dict[str, str]:
    opts: dict[str, str] = {}

    for token in tokens:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        opts[key.strip()] = value.strip().strip('"').strip("'")

    return opts


def parse_hls_pragmas(text: str, file_rel: str) -> list[HlsPragma]:
    pragmas: list[HlsPragma] = []

    for lineno, line in enumerate(text.splitlines(), start=1):
        if not re.search(r"#\s*pragma\s+HLS", line, flags=re.I):
            continue

        raw = line.strip()

        # Remove leading pragma marker but keep HLS directive body.
        body = re.sub(r"^\s*#\s*pragma\s+HLS\s*", "", raw, flags=re.I).strip()

        try:
            tokens = shlex.split(body)
        except ValueError:
            tokens = body.split()

        directive = tokens[0].lower() if tokens else "unknown"
        interface_type: str | None = None

        if directive == "interface" and len(tokens) >= 2:
            interface_type = tokens[1].lower()

        options = parse_pragma_options(tokens[1:] if directive != "interface" else tokens[2:])

        pragmas.append(
            HlsPragma(
                file=file_rel,
                line=lineno,
                raw=raw,
                directive=directive,
                interface_type=interface_type,
                options=options,
            )
        )

    return pragmas


def find_matching_brace(text: str, open_brace_index: int) -> int:
    depth = 0
    in_string = False
    in_char = False
    escape = False
    line_comment = False
    block_comment = False

    i = open_brace_index
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue

        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
                continue
            i += 1
            continue

        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if in_char:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "'":
                in_char = False
            i += 1
            continue

        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue

        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue

        if ch == '"':
            in_string = True
            i += 1
            continue

        if ch == "'":
            in_char = True
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i

        i += 1

    return len(text) - 1


def split_args(args_blob: str) -> list[str]:
    args: list[str] = []
    current = []
    angle = 0
    paren = 0
    bracket = 0

    for ch in args_blob:
        if ch == "<":
            angle += 1
        elif ch == ">" and angle > 0:
            angle -= 1
        elif ch == "(":
            paren += 1
        elif ch == ")" and paren > 0:
            paren -= 1
        elif ch == "[":
            bracket += 1
        elif ch == "]" and bracket > 0:
            bracket -= 1

        if ch == "," and angle == 0 and paren == 0 and bracket == 0:
            arg = "".join(current).strip()
            if arg:
                args.append(arg)
            current = []
        else:
            current.append(ch)

    final = "".join(current).strip()
    if final and final != "void":
        args.append(final)

    return args


def parse_argument(raw_arg: str) -> FunctionArgument:
    raw = " ".join(raw_arg.strip().split())
    cleaned = re.sub(r"=\s*.*$", "", raw).strip()
    cleaned = cleaned.replace(" const ", " const ")

    array = "[" in cleaned and "]" in cleaned
    pointer = "*" in cleaned
    reference = "&" in cleaned

    # Remove array suffix for name inference.
    name_blob = re.sub(r"\[[^\]]*\]", "", cleaned).strip()

    # Function pointer or unnamed argument fallback.
    if "(" in name_blob and ")" in name_blob:
        return FunctionArgument(raw=raw, name=None, type=cleaned, pointer=pointer, reference=reference, array=array)

    parts = name_blob.split()

    if not parts:
        return FunctionArgument(raw=raw, name=None, type=cleaned, pointer=pointer, reference=reference, array=array)

    candidate = parts[-1].strip("*&")
    if re.match(r"^[A-Za-z_]\w*$", candidate):
        name = candidate
        typ = name_blob[: name_blob.rfind(parts[-1])].strip()
        if not typ:
            typ = parts[0]
    else:
        name = None
        typ = cleaned

    return FunctionArgument(
        raw=raw,
        name=name,
        type=typ,
        pointer=pointer,
        reference=reference,
        array=array,
    )


def detect_extern_c_context(text: str, function_start: int) -> bool:
    prefix = text[max(0, function_start - 500):function_start]
    if re.search(r"extern\s+\"C\"\s*$", prefix, flags=re.S):
        return True
    if re.search(r"extern\s+\"C\"\s*\{\s*$", prefix, flags=re.S):
        return True

    # Also support extern "C" block that starts earlier.
    before = text[:function_start]
    block_starts = [m.start() for m in re.finditer(r"extern\s+\"C\"\s*\{", before)]
    if not block_starts:
        return False

    last_start = block_starts[-1]
    # If there are fewer closes than opens in this slice, the function is inside the block.
    slice_text = before[last_start:function_start]
    return slice_text.count("{") > slice_text.count("}")


def parse_functions(text: str, file_rel: str, includes: list[IncludeEdge], pragmas: list[HlsPragma]) -> list[HlsFunction]:
    functions: list[HlsFunction] = []
    clean = strip_comments_for_matching(text)

    # Conservative function definition matcher. It expects function definitions to start on a line.
    pattern = re.compile(
        r'(?m)^\s*((?:extern\s+"C"\s*)?(?:template\s*<[^;{}]+>\s*)?(?:(?:inline|static|constexpr|void|int|long|short|float|double|bool|char|unsigned|signed|auto|ap_uint\s*<[^>]+>|ap_int\s*<[^>]+>|hls::stream\s*<[^>]+>|[A-Za-z_][\w:<>]*)[\s\*&]+)+)([A-Za-z_]\w*)\s*\((.*?)\)\s*\{',
        re.S,
    )

    excluded_names = {"if", "for", "while", "switch", "catch"}

    for match in pattern.finditer(clean):
        name = match.group(2)
        if name in excluded_names:
            continue

        open_brace = match.end() - 1
        close_brace = find_matching_brace(clean, open_brace)

        line_start = clean.count("\n", 0, match.start()) + 1
        line_end = clean.count("\n", 0, close_brace) + 1

        return_type = " ".join(match.group(1).replace('extern "C"', "").split()).strip()
        args_blob = match.group(3)

        body = text[open_brace:close_brace + 1]
        function_pragmas = [p for p in pragmas if line_start <= p.line <= line_end]
        has_dataflow = any(p.directive.lower() == "dataflow" for p in function_pragmas)
        hls_stream_markers = len(re.findall(r"\bhls::stream\b", body))

        extern_c = detect_extern_c_context(clean, match.start()) or 'extern "C"' in match.group(1)

        candidate_reasons: list[str] = []
        if extern_c:
            candidate_reasons.append("extern_c")
        if any(p.directive == "interface" for p in function_pragmas):
            candidate_reasons.append("hls_interface_pragmas")
        if has_dataflow:
            candidate_reasons.append("dataflow")
        if hls_stream_markers:
            candidate_reasons.append("hls_stream_usage")

        is_kernel_candidate = bool(candidate_reasons)

        functions.append(
            HlsFunction(
                file=file_rel,
                name=name,
                line_start=line_start,
                line_end=line_end,
                return_type=return_type,
                args=[parse_argument(arg) for arg in split_args(args_blob)],
                extern_c=extern_c,
                pragmas=function_pragmas,
                includes=[i.include for i in includes],
                has_dataflow=has_dataflow,
                hls_stream_markers=hls_stream_markers,
                is_kernel_candidate=is_kernel_candidate,
                candidate_reasons=unique_sorted(candidate_reasons),
            )
        )

    return functions


def should_scan_source(path: Path, repo_root: Path, build_source_refs: set[str]) -> bool:
    if path.suffix.lower() not in SOURCE_EXTENSIONS:
        return False

    if any(part in EXCLUDED_DIRS for part in path.parts):
        return False

    rel = rel_path(repo_root, path)
    if rel in build_source_refs:
        return True

    text = read_text(path)
    if not text:
        return False

    markers = count_markers(text)
    return (
        markers["hls_pragmas"] > 0
        or markers["hls_stream"] > 0
        or markers["extern_c"] > 0
        or markers["ap_uint"] > 0
        or markers["ap_int"] > 0
    )


def collect_build_source_refs(build_ir: dict[str, Any] | None) -> set[str]:
    refs: set[str] = set()
    if not build_ir:
        return refs

    for ref in build_ir.get("summary", {}).get("source_refs", []):
        refs.add(ref.strip("./"))

    for bf in build_ir.get("build_files", []):
        for ref in bf.get("source_refs", []):
            refs.add(ref.strip("./"))

    return refs


def normalize_kernel_name(name: str) -> str:
    # Remove common compute-unit suffixes like _1, .inst, etc.
    name = name.strip()
    name = name.split(".")[0]
    name = re.sub(r"_[0-9]+$", "", name)
    return name


def collect_connectivity_kernels(connectivity_ir: dict[str, Any] | None) -> dict[str, list[str]]:
    configured: dict[str, list[str]] = defaultdict(list)

    if not connectivity_ir:
        return {}

    for d in connectivity_ir.get("compute_units", []):
        parsed = d.get("parsed", {})
        kernel = parsed.get("kernel")
        if kernel:
            configured[normalize_kernel_name(kernel)].append(d.get("file", "unknown"))
        for cu in parsed.get("compute_units", []) or []:
            configured[normalize_kernel_name(cu)].append(d.get("file", "unknown"))

    for d in connectivity_ir.get("memory_mappings", []):
        parsed = d.get("parsed", {})
        name = parsed.get("kernel_or_cu")
        if name:
            configured[normalize_kernel_name(name)].append(d.get("file", "unknown"))

    for d in connectivity_ir.get("stream_edges", []):
        parsed = d.get("parsed", {})
        for key in ["src_kernel_or_cu", "dst_kernel_or_cu"]:
            name = parsed.get(key)
            if name:
                configured[normalize_kernel_name(name)].append(d.get("file", "unknown"))

    return {k: unique_sorted(v) for k, v in sorted(configured.items())}


def flatten_interfaces(functions: list[HlsFunction]) -> list[dict[str, Any]]:
    interfaces: list[dict[str, Any]] = []

    for fn in functions:
        for pragma in fn.pragmas:
            if pragma.directive != "interface":
                continue

            interfaces.append({
                "file": fn.file,
                "function": fn.name,
                "line": pragma.line,
                "interface_type": pragma.interface_type,
                "port": pragma.options.get("port"),
                "bundle": pragma.options.get("bundle"),
                "offset": pragma.options.get("offset"),
                "depth": pragma.options.get("depth"),
                "mode": pragma.options.get("mode"),
                "raw": pragma.raw,
                "options": pragma.options,
            })

    return interfaces


def build_hls_interface_ir(
    repo_path: str,
    build_ir_path: str | None = None,
    connectivity_ir_path: str | None = None,
) -> dict[str, Any]:
    root = Path(repo_path).resolve()
    build = load_json_optional(build_ir_path)
    conn = load_json_optional(connectivity_ir_path)

    build_source_refs = collect_build_source_refs(build)

    files: list[HlsFileIR] = []

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue

        if ".git" in path.parts:
            continue

        if not should_scan_source(path, root, build_source_refs):
            continue

        rel = rel_path(root, path)
        text = read_text(path)
        if not text:
            continue

        includes = parse_includes(text, rel)
        pragmas = parse_hls_pragmas(text, rel)
        functions = parse_functions(text, rel, includes, pragmas)
        markers = {k: v for k, v in count_markers(text).items() if v}

        files.append(
            HlsFileIR(
                path=rel,
                includes=includes,
                pragmas=pragmas,
                functions=functions,
                markers=markers,
            )
        )

    all_functions: list[HlsFunction] = []
    all_pragmas: list[HlsPragma] = []
    include_edges: list[IncludeEdge] = []

    for f in files:
        all_functions.extend(f.functions)
        all_pragmas.extend(f.pragmas)
        include_edges.extend(f.includes)

    kernel_candidates = [fn for fn in all_functions if fn.is_kernel_candidate]
    interfaces = flatten_interfaces(kernel_candidates)

    interface_counts = Counter(i.get("interface_type") or "unknown" for i in interfaces)
    directive_counts = Counter(p.directive for p in all_pragmas)

    configured = collect_connectivity_kernels(conn)
    declared_kernel_names = unique_sorted([fn.name for fn in kernel_candidates])
    declared_normalized = {normalize_kernel_name(name): name for name in declared_kernel_names}

    matched = []
    missing_declared_for_config = []
    for configured_name, sources in configured.items():
        if configured_name in declared_normalized:
            matched.append({
                "configured_kernel": configured_name,
                "declared_kernel": declared_normalized[configured_name],
                "sources": sources,
            })
        else:
            missing_declared_for_config.append({
                "configured_kernel": configured_name,
                "sources": sources,
            })

    missing_config_for_declared = []
    configured_names = set(configured.keys())
    for declared_name in declared_kernel_names:
        norm = normalize_kernel_name(declared_name)
        if configured and norm not in configured_names:
            missing_config_for_declared.append(declared_name)

    stream_variables = []
    stream_pattern = re.compile(r"hls::stream\s*<([^>]+)>\s+([A-Za-z_]\w*)")
    for f in files:
        text = read_text(root / f.path)
        for match in stream_pattern.finditer(text):
            stream_variables.append({
                "file": f.path,
                "line": text.count("\n", 0, match.start()) + 1,
                "type": match.group(1).strip(),
                "name": match.group(2).strip(),
            })

    return {
        "schema_version": "hls_interface_ir.v1",
        "repo_path": str(root),
        "created_at_utc": utc_now(),
        "build_ir_ref": build_ir_path,
        "connectivity_ir_ref": connectivity_ir_path,
        "files": [
            {
                **asdict(f),
                "includes": [asdict(i) for i in f.includes],
                "pragmas": [asdict(p) for p in f.pragmas],
                "functions": [
                    {
                        **asdict(fn),
                        "args": [asdict(a) for a in fn.args],
                        "pragmas": [asdict(p) for p in fn.pragmas],
                    }
                    for fn in f.functions
                ],
            }
            for f in files
        ],
        "kernels": [
            {
                **asdict(fn),
                "args": [asdict(a) for a in fn.args],
                "pragmas": [asdict(p) for p in fn.pragmas],
            }
            for fn in kernel_candidates
        ],
        "interfaces": interfaces,
        "stream_variables": stream_variables,
        "include_graph": [asdict(i) for i in include_edges],
        "connectivity_alignment": {
            "configured_kernels": configured,
            "declared_kernels": declared_kernel_names,
            "matched": matched,
            "missing_declared_for_config": missing_declared_for_config,
            "missing_config_for_declared": missing_config_for_declared,
        },
        "summary": {
            "num_hls_files": len(files),
            "num_functions": len(all_functions),
            "num_kernel_candidates": len(kernel_candidates),
            "num_pragmas": len(all_pragmas),
            "pragma_directives": dict(sorted(directive_counts.items())),
            "num_interface_pragmas": len(interfaces),
            "interface_types": dict(sorted(interface_counts.items())),
            "num_m_axi": interface_counts.get("m_axi", 0),
            "num_axis": interface_counts.get("axis", 0),
            "num_s_axilite": interface_counts.get("s_axilite", 0),
            "num_dataflow": directive_counts.get("dataflow", 0),
            "num_hls_stream_markers": sum(f.markers.get("hls_stream", 0) for f in files),
            "num_stream_variables": len(stream_variables),
            "num_include_edges": len(include_edges),
            "num_configured_kernels": len(configured),
            "num_matched_configured_kernels": len(matched),
            "num_missing_declared_for_config": len(missing_declared_for_config),
            "num_missing_config_for_declared": len(missing_config_for_declared),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract HLS Interface IR from a real Vitis/XRT repository")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--build-ir", default=None)
    parser.add_argument("--connectivity-ir", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    ir = build_hls_interface_ir(
        repo_path=args.repo,
        build_ir_path=args.build_ir,
        connectivity_ir_path=args.connectivity_ir,
    )
    save_json(args.out, ir)

    s = ir["summary"]
    print(f"[xporthls] HLS Interface IR written to: {args.out}")
    print(f"[xporthls] HLS files: {s['num_hls_files']}")
    print(f"[xporthls] Functions: {s['num_functions']}")
    print(f"[xporthls] Kernel candidates: {s['num_kernel_candidates']}")
    print(f"[xporthls] Interface pragmas: {s['num_interface_pragmas']}")
    print(f"[xporthls] m_axi: {s['num_m_axi']}")
    print(f"[xporthls] axis: {s['num_axis']}")
    print(f"[xporthls] s_axilite: {s['num_s_axilite']}")
    print(f"[xporthls] dataflow: {s['num_dataflow']}")
    print(f"[xporthls] stream variables: {s['num_stream_variables']}")
    print(f"[xporthls] include edges: {s['num_include_edges']}")
    print(f"[xporthls] matched configured kernels: {s['num_matched_configured_kernels']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
