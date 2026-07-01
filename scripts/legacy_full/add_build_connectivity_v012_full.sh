#!/usr/bin/env bash
set -e

echo "[1/7] Add BuildIR + ConnectivityIR extractor"

mkdir -p xporthls/realrepo
touch xporthls/realrepo/__init__.py

cat > xporthls/realrepo/build_connectivity_extractor.py <<'EOT'
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


BUILD_FILE_NAMES = {"Makefile", "makefile", "CMakeLists.txt", "makefile_us_alveo.mk"}
CONFIG_EXTENSIONS = {".ini", ".cfg"}
TEXT_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx",
    ".mk", ".cmake", ".ini", ".cfg", ".tcl", ".sh", ".txt", ".md",
    ""
}


@dataclass
class BuildCommand:
    file: str
    line: int
    kind: str
    command: str
    platform_strings: list[str] = field(default_factory=list)
    config_refs: list[str] = field(default_factory=list)
    source_refs: list[str] = field(default_factory=list)
    output_refs: list[str] = field(default_factory=list)
    kernel_refs: list[str] = field(default_factory=list)


@dataclass
class BuildFileIR:
    path: str
    kind: str
    variables: dict[str, str] = field(default_factory=dict)
    targets: list[dict[str, Any]] = field(default_factory=list)
    commands: list[BuildCommand] = field(default_factory=list)
    platform_strings: list[str] = field(default_factory=list)
    config_refs: list[str] = field(default_factory=list)
    xclbin_refs: list[str] = field(default_factory=list)
    xo_refs: list[str] = field(default_factory=list)
    source_refs: list[str] = field(default_factory=list)


@dataclass
class ConnectivityDirective:
    file: str
    line: int
    section: str | None
    key: str
    value: str
    raw: str
    parsed: dict[str, Any] = field(default_factory=dict)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_text(path: Path, max_bytes: int = 5_000_000) -> str:
    try:
        if path.stat().st_size > max_bytes:
            return ""
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def unique_sorted(items: list[str]) -> list[str]:
    return sorted({x for x in items if x})


def rel_path(root: Path, path: Path) -> str:
    return str(path.resolve().relative_to(root.resolve()))


def normalize_make_lines(text: str) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    current = ""
    start_line = 1

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip()

        if current == "":
            start_line = lineno

        if line.endswith("\\"):
            current += line[:-1] + " "
            continue

        current += line
        out.append((start_line, current))
        current = ""

    if current:
        out.append((start_line, current))

    return out


def strip_inline_comment(line: str) -> str:
    # Conservative: strip comments only when # is the first non-space char or preceded by whitespace.
    out = []
    for i, ch in enumerate(line):
        if ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        out.append(ch)
    return "".join(out).strip()


def find_build_files(repo_root: Path) -> list[Path]:
    files: list[Path] = []

    for path in sorted(repo_root.rglob("*")):
        if not path.is_file():
            continue

        if ".git" in path.parts:
            continue

        if path.name in BUILD_FILE_NAMES or path.suffix.lower() in {".mk", ".cmake"}:
            files.append(path)

    return files


def find_config_files(repo_root: Path) -> list[Path]:
    files: list[Path] = []

    for path in sorted(repo_root.rglob("*")):
        if not path.is_file():
            continue

        if ".git" in path.parts:
            continue

        if path.suffix.lower() in CONFIG_EXTENSIONS:
            files.append(path)

    return files


def extract_tokens(command: str) -> dict[str, list[str]]:
    platform_strings = re.findall(r"xilinx_[A-Za-z0-9_]+", command)

    config_refs = []
    config_refs += re.findall(r"--config(?:=|\s+)([^\s]+)", command)
    config_refs += re.findall(r"(?:^|\s)([A-Za-z0-9_./-]+\.(?:ini|cfg))(?:\s|$)", command)

    source_refs = re.findall(r"(?:^|\s)([A-Za-z0-9_./-]+\.(?:cpp|cc|cxx|c|hpp|hh|h))(?:\s|$)", command)
    output_refs = []
    output_refs += re.findall(r"(?:-o|--output)(?:=|\s+)([^\s]+)", command)
    output_refs += re.findall(r"(?:^|\s)([A-Za-z0-9_./-]+\.(?:xo|xclbin|exe|elf))(?:\s|$)", command)

    kernel_refs = []
    kernel_refs += re.findall(r"--kernel(?:=|\s+)([A-Za-z0-9_]+)", command)
    kernel_refs += re.findall(r"-k\s+([A-Za-z0-9_]+)", command)

    return {
        "platform_strings": unique_sorted(platform_strings),
        "config_refs": unique_sorted([x.strip("'\"") for x in config_refs]),
        "source_refs": unique_sorted([x.strip("'\"") for x in source_refs]),
        "output_refs": unique_sorted([x.strip("'\"") for x in output_refs]),
        "kernel_refs": unique_sorted(kernel_refs),
    }


def command_kind(line: str) -> str | None:
    lower = line.lower()

    if "v++" in line or "$(vpp)" in lower or "${vpp}" in lower or re.search(r"\bVPP\b", line):
        return "vpp"

    if "vitis_hls" in lower:
        return "vitis_hls"

    if re.search(r"(^|\s)(g\+\+|gcc|clang\+\+|clang)\b", line):
        return "host_compile"

    if re.search(r"(^|\s)make\b", line):
        return "make"

    if ".xclbin" in lower or ".xo" in lower:
        return "artifact_reference"

    return None


def parse_build_file(repo_root: Path, path: Path) -> BuildFileIR:
    text = read_text(path)
    rel = rel_path(repo_root, path)

    kind = "cmake" if path.name == "CMakeLists.txt" or path.suffix.lower() == ".cmake" else "makefile"

    variables: dict[str, str] = {}
    targets: list[dict[str, Any]] = []
    commands: list[BuildCommand] = []

    platform_strings: list[str] = []
    config_refs: list[str] = []
    xclbin_refs: list[str] = []
    xo_refs: list[str] = []
    source_refs: list[str] = []

    var_re = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*([:+?]?=)\s*(.*)$")
    target_re = re.compile(r"^([A-Za-z0-9_./%+ -]+)\s*:(?![=])\s*(.*)$")

    for lineno, line in normalize_make_lines(text):
        stripped = strip_inline_comment(line)
        if not stripped:
            continue

        m_var = var_re.match(stripped)
        if m_var:
            name, op, value = m_var.groups()
            variables[name] = value.strip()

            combined = f"{name}={value}"
            tokens = extract_tokens(combined)
            platform_strings.extend(tokens["platform_strings"])
            config_refs.extend(tokens["config_refs"])
            source_refs.extend(tokens["source_refs"])
            xclbin_refs.extend([x for x in tokens["output_refs"] if x.endswith(".xclbin")])
            xo_refs.extend([x for x in tokens["output_refs"] if x.endswith(".xo")])
            continue

        m_target = target_re.match(stripped)
        if m_target and not stripped.startswith("\t"):
            target_blob, deps = m_target.groups()
            for target in target_blob.split():
                if target and not target.startswith("."):
                    targets.append({
                        "name": target,
                        "line": lineno,
                        "dependencies": deps.split()
                    })

        kind_detected = command_kind(stripped)
        if kind_detected:
            tokens = extract_tokens(stripped)
            command = BuildCommand(
                file=rel,
                line=lineno,
                kind=kind_detected,
                command=stripped,
                platform_strings=tokens["platform_strings"],
                config_refs=tokens["config_refs"],
                source_refs=tokens["source_refs"],
                output_refs=tokens["output_refs"],
                kernel_refs=tokens["kernel_refs"],
            )
            commands.append(command)

            platform_strings.extend(tokens["platform_strings"])
            config_refs.extend(tokens["config_refs"])
            source_refs.extend(tokens["source_refs"])
            xclbin_refs.extend([x for x in tokens["output_refs"] if x.endswith(".xclbin")])
            xo_refs.extend([x for x in tokens["output_refs"] if x.endswith(".xo")])

    # Extract artifact-like references from full text as a fallback.
    xclbin_refs.extend(re.findall(r"[A-Za-z0-9_./-]+\.xclbin", text))
    xo_refs.extend(re.findall(r"[A-Za-z0-9_./-]+\.xo", text))
    source_refs.extend(re.findall(r"[A-Za-z0-9_./-]+\.(?:cpp|cc|cxx|c|hpp|hh|h)", text))
    config_refs.extend(re.findall(r"[A-Za-z0-9_./-]+\.(?:ini|cfg)", text))
    platform_strings.extend(re.findall(r"xilinx_[A-Za-z0-9_]+", text))

    return BuildFileIR(
        path=rel,
        kind=kind,
        variables=variables,
        targets=targets,
        commands=commands,
        platform_strings=unique_sorted(platform_strings),
        config_refs=unique_sorted(config_refs),
        xclbin_refs=unique_sorted(xclbin_refs),
        xo_refs=unique_sorted(xo_refs),
        source_refs=unique_sorted(source_refs),
    )


def parse_sp_directive(value: str) -> dict[str, Any]:
    # Examples:
    # sp=kernel_1.m_axi_gmem:HBM[0]
    # sp=spmv_sk0_1.matrix_hbm_0:HBM[0]
    left, sep, bank = value.partition(":")
    parsed: dict[str, Any] = {
        "raw_left": left.strip(),
        "memory": bank.strip() if sep else None,
    }

    if "." in left:
        instance, port = left.rsplit(".", 1)
        parsed["kernel_or_cu"] = instance.strip()
        parsed["port"] = port.strip()
    else:
        parsed["kernel_or_cu"] = left.strip()
        parsed["port"] = None

    parsed["memory_kind"] = None
    parsed["memory_indices"] = []

    if parsed["memory"]:
        mem = parsed["memory"]
        m = re.search(r"([A-Za-z_]+)\[([0-9:]+)\]", mem)
        if m:
            parsed["memory_kind"] = m.group(1)
            idx = m.group(2)
            parsed["memory_indices"] = [idx]
        else:
            m2 = re.search(r"([A-Za-z_]+)([0-9]+)", mem)
            if m2:
                parsed["memory_kind"] = m2.group(1)
                parsed["memory_indices"] = [m2.group(2)]

    return parsed


def parse_nk_directive(value: str) -> dict[str, Any]:
    # Examples:
    # nk=vadd:2:vadd_1.vadd_2
    # nk=spmv_sk0:1:spmv_sk0_1
    parts = [p.strip() for p in value.split(":")]
    parsed: dict[str, Any] = {
        "kernel": parts[0] if parts else None,
        "count": None,
        "compute_units": [],
    }

    if len(parts) >= 2:
        try:
            parsed["count"] = int(parts[1])
        except ValueError:
            parsed["count"] = parts[1]

    if len(parts) >= 3:
        parsed["compute_units"] = [x for x in re.split(r"[.,]", parts[2]) if x]

    return parsed


def parse_stream_directive(value: str) -> dict[str, Any]:
    # Examples:
    # stream_connect=src.out:dst.in
    # sc=src.out:dst.in
    src, sep, dst = value.partition(":")
    parsed = {
        "src": src.strip(),
        "dst": dst.strip() if sep else None,
    }

    if "." in parsed["src"]:
        parsed["src_kernel_or_cu"], parsed["src_port"] = parsed["src"].rsplit(".", 1)
    else:
        parsed["src_kernel_or_cu"], parsed["src_port"] = parsed["src"], None

    if parsed["dst"] and "." in parsed["dst"]:
        parsed["dst_kernel_or_cu"], parsed["dst_port"] = parsed["dst"].rsplit(".", 1)
    else:
        parsed["dst_kernel_or_cu"], parsed["dst_port"] = parsed["dst"], None

    return parsed


def parse_slr_directive(value: str) -> dict[str, Any]:
    left, sep, slr = value.partition(":")
    return {
        "kernel_or_cu": left.strip(),
        "slr": slr.strip() if sep else None,
    }


def parse_connectivity_file(repo_root: Path, path: Path) -> list[ConnectivityDirective]:
    text = read_text(path)
    rel = rel_path(repo_root, path)
    section: str | None = None
    directives: list[ConnectivityDirective] = []

    for lineno, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.strip()

        if not stripped:
            continue

        if stripped.startswith("#") or stripped.startswith(";"):
            continue

        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1].strip()
            continue

        line = strip_inline_comment(stripped)
        if not line or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        parsed: dict[str, Any] = {}

        if key == "sp":
            parsed = parse_sp_directive(value)
        elif key == "nk":
            parsed = parse_nk_directive(value)
        elif key in {"stream_connect", "sc"}:
            parsed = parse_stream_directive(value)
        elif key == "slr":
            parsed = parse_slr_directive(value)
        else:
            parsed = {"value": value}

        directives.append(
            ConnectivityDirective(
                file=rel,
                line=lineno,
                section=section,
                key=key,
                value=value,
                raw=raw,
                parsed=parsed,
            )
        )

    return directives


def collect_connectivity_from_build(build_files: list[BuildFileIR]) -> list[ConnectivityDirective]:
    directives: list[ConnectivityDirective] = []

    option_patterns = [
        ("sp", re.compile(r"(?:--sp|sp=)(?:=|\s+)?([A-Za-z0-9_./:\[\]-]+)")),
        ("nk", re.compile(r"(?:--nk|nk=)(?:=|\s+)?([A-Za-z0-9_./:\[\]-]+)")),
        ("stream_connect", re.compile(r"(?:--sc|--stream_connect|stream_connect=|sc=)(?:=|\s+)?([A-Za-z0-9_./:\[\]-]+)")),
        ("slr", re.compile(r"(?:--slr|slr=)(?:=|\s+)?([A-Za-z0-9_./:\[\]-]+)")),
    ]

    for bf in build_files:
        for cmd in bf.commands:
            for key, pattern in option_patterns:
                for value in pattern.findall(cmd.command):
                    if key == "sp":
                        parsed = parse_sp_directive(value)
                    elif key == "nk":
                        parsed = parse_nk_directive(value)
                    elif key == "stream_connect":
                        parsed = parse_stream_directive(value)
                    elif key == "slr":
                        parsed = parse_slr_directive(value)
                    else:
                        parsed = {"value": value}

                    directives.append(
                        ConnectivityDirective(
                            file=cmd.file,
                            line=cmd.line,
                            section="build_command",
                            key=key,
                            value=value,
                            raw=cmd.command,
                            parsed=parsed,
                        )
                    )

    return directives


def build_ir(repo_path: str) -> dict[str, Any]:
    root = Path(repo_path).resolve()
    build_paths = find_build_files(root)
    build_files = [parse_build_file(root, p) for p in build_paths]

    all_commands = []
    all_platforms = []
    all_config_refs = []
    all_xclbin_refs = []
    all_xo_refs = []
    all_source_refs = []
    all_targets = []

    for bf in build_files:
        all_commands.extend(asdict(c) for c in bf.commands)
        all_platforms.extend(bf.platform_strings)
        all_config_refs.extend(bf.config_refs)
        all_xclbin_refs.extend(bf.xclbin_refs)
        all_xo_refs.extend(bf.xo_refs)
        all_source_refs.extend(bf.source_refs)
        for target in bf.targets:
            all_targets.append({"file": bf.path, **target})

    command_kinds = Counter(c["kind"] for c in all_commands)

    return {
        "schema_version": "build_ir.v1",
        "repo_path": str(root),
        "created_at_utc": utc_now(),
        "build_files": [
            {
                **asdict(bf),
                "commands": [asdict(c) for c in bf.commands],
            }
            for bf in build_files
        ],
        "summary": {
            "num_build_files": len(build_files),
            "num_targets": len(all_targets),
            "num_commands": len(all_commands),
            "command_kinds": dict(sorted(command_kinds.items())),
            "detected_platforms": unique_sorted(all_platforms),
            "config_refs": unique_sorted(all_config_refs),
            "xclbin_refs": unique_sorted(all_xclbin_refs),
            "xo_refs": unique_sorted(all_xo_refs),
            "source_refs": unique_sorted(all_source_refs),
        },
        "targets": all_targets,
        "commands": all_commands,
    }


def connectivity_ir(repo_path: str, build: dict[str, Any]) -> dict[str, Any]:
    root = Path(repo_path).resolve()
    config_paths = find_config_files(root)

    directives: list[ConnectivityDirective] = []
    for p in config_paths:
        directives.extend(parse_connectivity_file(root, p))

    build_files = []
    for bf in build.get("build_files", []):
        obj = BuildFileIR(
            path=bf["path"],
            kind=bf["kind"],
            variables=bf.get("variables", {}),
            targets=bf.get("targets", []),
            commands=[BuildCommand(**c) for c in bf.get("commands", [])],
            platform_strings=bf.get("platform_strings", []),
            config_refs=bf.get("config_refs", []),
            xclbin_refs=bf.get("xclbin_refs", []),
            xo_refs=bf.get("xo_refs", []),
            source_refs=bf.get("source_refs", []),
        )
        build_files.append(obj)

    directives.extend(collect_connectivity_from_build(build_files))

    memory_mappings = [asdict(d) for d in directives if d.key == "sp"]
    compute_units = [asdict(d) for d in directives if d.key == "nk"]
    stream_edges = [asdict(d) for d in directives if d.key in {"stream_connect", "sc"}]
    slr_assignments = [asdict(d) for d in directives if d.key == "slr"]
    other_options = [asdict(d) for d in directives if d.key not in {"sp", "nk", "stream_connect", "sc", "slr"}]

    memory_kinds = []
    for d in memory_mappings:
        kind = d.get("parsed", {}).get("memory_kind")
        if kind:
            memory_kinds.append(kind)

    return {
        "schema_version": "connectivity_ir.v1",
        "repo_path": str(root),
        "created_at_utc": utc_now(),
        "config_files": [rel_path(root, p) for p in config_paths],
        "directives": [asdict(d) for d in directives],
        "memory_mappings": memory_mappings,
        "compute_units": compute_units,
        "stream_edges": stream_edges,
        "slr_assignments": slr_assignments,
        "other_options": other_options,
        "summary": {
            "num_config_files": len(config_paths),
            "num_directives": len(directives),
            "num_memory_mappings": len(memory_mappings),
            "num_compute_unit_directives": len(compute_units),
            "num_stream_edges": len(stream_edges),
            "num_slr_assignments": len(slr_assignments),
            "memory_kinds": unique_sorted(memory_kinds),
        },
    }


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract BuildIR and ConnectivityIR from a real Vitis/XRT repository")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--build-out", required=True)
    parser.add_argument("--connectivity-out", required=True)
    args = parser.parse_args()

    build = build_ir(args.repo)
    conn = connectivity_ir(args.repo, build)

    save_json(args.build_out, build)
    save_json(args.connectivity_out, conn)

    print(f"[xporthls] BuildIR written to: {args.build_out}")
    print(f"[xporthls] ConnectivityIR written to: {args.connectivity_out}")
    print(f"[xporthls] Build files: {build['summary']['num_build_files']}")
    print(f"[xporthls] Build targets: {build['summary']['num_targets']}")
    print(f"[xporthls] Build commands: {build['summary']['num_commands']}")
    print(f"[xporthls] Detected platforms: {build['summary']['detected_platforms']}")
    print(f"[xporthls] Config files: {conn['summary']['num_config_files']}")
    print(f"[xporthls] Connectivity directives: {conn['summary']['num_directives']}")
    print(f"[xporthls] Memory mappings: {conn['summary']['num_memory_mappings']}")
    print(f"[xporthls] Stream edges: {conn['summary']['num_stream_edges']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/7] Add BuildIR + ConnectivityIR validator"

cat > xporthls/realrepo/validate_build_connectivity_v012.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class BuildConnectivityIssue:
    severity: str
    code: str
    message: str


@dataclass
class BuildConnectivityValidationReport:
    status: str
    issues: list[BuildConnectivityIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def validate(build: dict[str, Any], conn: dict[str, Any]) -> BuildConnectivityValidationReport:
    issues: list[BuildConnectivityIssue] = []

    if build.get("schema_version") != "build_ir.v1":
        issues.append(BuildConnectivityIssue("error", "BUILD_IR_SCHEMA", "Expected build_ir.v1."))

    if conn.get("schema_version") != "connectivity_ir.v1":
        issues.append(BuildConnectivityIssue("error", "CONNECTIVITY_IR_SCHEMA", "Expected connectivity_ir.v1."))

    bsum = build.get("summary", {})
    csum = conn.get("summary", {})

    if bsum.get("num_build_files", 0) <= 0:
        issues.append(BuildConnectivityIssue("error", "NO_BUILD_FILES", "No build files were found."))

    if bsum.get("num_targets", 0) <= 0:
        issues.append(BuildConnectivityIssue("warning", "NO_BUILD_TARGETS", "No Makefile/CMake targets were detected."))

    if not bsum.get("detected_platforms"):
        issues.append(BuildConnectivityIssue("warning", "NO_PLATFORM_STRING", "No xilinx_* platform string was detected in build files."))

    if csum.get("num_config_files", 0) <= 0:
        issues.append(BuildConnectivityIssue("warning", "NO_CONNECTIVITY_CONFIGS", "No .ini/.cfg connectivity files were found."))

    if csum.get("num_directives", 0) <= 0:
        issues.append(BuildConnectivityIssue("warning", "NO_CONNECTIVITY_DIRECTIVES", "No connectivity directives were parsed."))

    if csum.get("num_memory_mappings", 0) <= 0:
        issues.append(BuildConnectivityIssue("warning", "NO_MEMORY_MAPPINGS", "No sp= memory mappings were parsed."))

    # For HiSparse-like projects, HBM is expected. This is warning only because the extractor must remain generic.
    if bsum.get("detected_platforms") and csum.get("num_memory_mappings", 0) > 0:
        memory_kinds = csum.get("memory_kinds", [])
        if memory_kinds and not any(str(k).upper().startswith("HBM") for k in memory_kinds):
            issues.append(BuildConnectivityIssue("warning", "NO_HBM_MEMORY_KIND", "Connectivity mappings exist but no HBM memory kind was detected."))

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return BuildConnectivityValidationReport(
        status=status,
        issues=issues,
        summary={
            "num_build_files": bsum.get("num_build_files"),
            "num_targets": bsum.get("num_targets"),
            "num_commands": bsum.get("num_commands"),
            "command_kinds": bsum.get("command_kinds"),
            "detected_platforms": bsum.get("detected_platforms"),
            "config_refs": bsum.get("config_refs"),
            "num_config_files": csum.get("num_config_files"),
            "num_directives": csum.get("num_directives"),
            "num_memory_mappings": csum.get("num_memory_mappings"),
            "num_compute_unit_directives": csum.get("num_compute_unit_directives"),
            "num_stream_edges": csum.get("num_stream_edges"),
            "num_slr_assignments": csum.get("num_slr_assignments"),
            "memory_kinds": csum.get("memory_kinds"),
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate BuildIR and ConnectivityIR")
    parser.add_argument("--build-ir", required=True)
    parser.add_argument("--connectivity-ir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    build = load_json(args.build_ir)
    conn = load_json(args.connectivity_ir)

    report = validate(build, conn)
    report.save(args.out)

    print(f"[xporthls] Build/Connectivity validation written to: {args.out}")
    print(f"[xporthls] Build/Connectivity validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[3/7] Add v0.0.12 orchestration runner"

cat > xporthls/realrepo/run_build_connectivity_v012.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.build_connectivity_extractor import build_ir, connectivity_ir, save_json
from xporthls.realrepo.validate_build_connectivity_v012 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.12 BuildIR + ConnectivityIR extraction pipeline")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--case-id", default="hisparse")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    build_path = out_dir / f"{args.case_id}_build_ir_v012.json"
    conn_path = out_dir / f"{args.case_id}_connectivity_ir_v012.json"
    report_path = out_dir / f"{args.case_id}_build_connectivity_report_v012.json"

    build = build_ir(args.repo)
    conn = connectivity_ir(args.repo, build)

    save_json(str(build_path), build)
    save_json(str(conn_path), conn)

    report = validate(build, conn)
    report.save(str(report_path))

    print(f"[xporthls] BuildIR: {build_path}")
    print(f"[xporthls] ConnectivityIR: {conn_path}")
    print(f"[xporthls] Validation report: {report_path}")
    print(f"[xporthls] Build files: {build['summary']['num_build_files']}")
    print(f"[xporthls] Targets: {build['summary']['num_targets']}")
    print(f"[xporthls] Commands: {build['summary']['num_commands']}")
    print(f"[xporthls] Platforms: {build['summary']['detected_platforms']}")
    print(f"[xporthls] Config files: {conn['summary']['num_config_files']}")
    print(f"[xporthls] Directives: {conn['summary']['num_directives']}")
    print(f"[xporthls] Memory mappings: {conn['summary']['num_memory_mappings']}")
    print(f"[xporthls] Compute-unit directives: {conn['summary']['num_compute_unit_directives']}")
    print(f"[xporthls] Stream edges: {conn['summary']['num_stream_edges']}")
    print(f"[xporthls] SLR assignments: {conn['summary']['num_slr_assignments']}")
    print(f"[xporthls] Memory kinds: {conn['summary']['memory_kinds']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/7] Update compatibility profiler recommendation for v0.0.12 completion"

python3 - <<'PY'
from pathlib import Path

p = Path("xporthls/realrepo/compatibility_profiler.py")
if p.exists():
    text = p.read_text(encoding="utf-8")
    text = text.replace(
        '"version": "v0.0.12",\n            "name": "Vitis Build + Connectivity Extractor",\n            "why": "The profile shows real projects need Makefile/v++/connectivity parsing before ApplicationIR can represent them."',
        '"version": "v0.0.13",\n            "name": "HLS Interface Extractor v1",\n            "why": "After BuildIR and ConnectivityIR, the next required layer is extracting HLS interfaces, m_axi bundles, AXIS ports and dataflow pragmas."'
    )
    p.write_text(text, encoding="utf-8")
else:
    print("compatibility_profiler.py not found; skipping recommendation update")
PY

echo "[5/7] Update README with BuildIR/ConnectivityIR usage"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Build and connectivity extraction

XPortHLS can extract build and connectivity facts from a real Vitis/XRT repository. This produces a BuildIR and ConnectivityIR used by later migration stages.

Example:

```bash
python3 -m xporthls.realrepo.run_build_connectivity_v012 \\
  --repo /mnt/data/xporthls_benchmarks/HiSparse \\
  --case-id hisparse
```

The extractor writes:

```text
experiments/runs/hisparse_build_ir_v012.json
experiments/runs/hisparse_connectivity_ir_v012.json
experiments/runs/hisparse_build_connectivity_report_v012.json
```

The extractor is analysis-only. It does not generate an AVED project.
"""

if "## Build and connectivity extraction" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[6/7] Create v0.0.12 replay script"

cat > add_build_connectivity_v012_replay.sh <<'EOT'
#!/usr/bin/env bash
set -e

HISPARSE_DIR="${HISPARSE_DIR:-/mnt/data/xporthls_benchmarks/HiSparse}"

echo "[v0.0.12] Python syntax check"

python3 -m py_compile \
  xporthls/realrepo/build_connectivity_extractor.py \
  xporthls/realrepo/validate_build_connectivity_v012.py \
  xporthls/realrepo/run_build_connectivity_v012.py \
  xporthls/realrepo/repo_census.py \
  xporthls/realrepo/source_platform_profiler.py \
  xporthls/realrepo/compatibility_profiler.py \
  xporthls/realrepo/validate_realrepo_profile_v011.py \
  xporthls/realrepo/run_realrepo_profile_v011.py

echo "[v0.0.12] Ensure HiSparse checkout exists"

mkdir -p "$(dirname "$HISPARSE_DIR")"

if [ ! -d "$HISPARSE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/cornell-zhang/HiSparse.git "$HISPARSE_DIR"
else
  git -C "$HISPARSE_DIR" checkout master
  git -C "$HISPARSE_DIR" pull --ff-only || true
fi

echo "[v0.0.12] Re-run v0.0.11 profile for fresh baseline"

python3 -m xporthls.realrepo.run_realrepo_profile_v011 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --out-dir experiments/runs

echo "[v0.0.12] Run BuildIR + ConnectivityIR extraction"

python3 -m xporthls.realrepo.run_build_connectivity_v012 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --out-dir experiments/runs

python3 - <<'PY'
import json

census = json.load(open("experiments/runs/hisparse_repo_census_v011.json"))
source = json.load(open("experiments/runs/hisparse_source_platform_profile_v011.json"))
build = json.load(open("experiments/runs/hisparse_build_ir_v012.json"))
conn = json.load(open("experiments/runs/hisparse_connectivity_ir_v012.json"))
report = json.load(open("experiments/runs/hisparse_build_connectivity_report_v012.json"))

print()
print("Census schema:", census["schema_version"])
print("Source runtime:", source["source_runtime"])
print("Source boards:", source["source_boards_detected"])
print("BuildIR schema:", build["schema_version"])
print("ConnectivityIR schema:", conn["schema_version"])
print("Validation status:", report["status"])
print("Build files:", build["summary"]["num_build_files"])
print("Targets:", build["summary"]["num_targets"])
print("Commands:", build["summary"]["num_commands"])
print("Command kinds:", build["summary"]["command_kinds"])
print("Detected platforms:", build["summary"]["detected_platforms"])
print("Config refs:", build["summary"]["config_refs"])
print("Config files:", conn["summary"]["num_config_files"])
print("Directives:", conn["summary"]["num_directives"])
print("Memory mappings:", conn["summary"]["num_memory_mappings"])
print("Compute-unit directives:", conn["summary"]["num_compute_unit_directives"])
print("Stream edges:", conn["summary"]["num_stream_edges"])
print("SLR assignments:", conn["summary"]["num_slr_assignments"])
print("Memory kinds:", conn["summary"]["memory_kinds"])

assert census["schema_version"] == "repo_census.v1"
assert source["source_runtime"] == "XRT"
assert build["schema_version"] == "build_ir.v1"
assert conn["schema_version"] == "connectivity_ir.v1"
assert report["status"] in {"pass", "pass_with_warnings"}
assert build["summary"]["num_build_files"] > 0
assert conn["summary"]["num_config_files"] > 0
assert conn["summary"]["num_directives"] > 0
assert conn["summary"]["num_memory_mappings"] > 0
assert "U280" in source["source_boards_detected"] or build["summary"]["detected_platforms"]
PY

echo
echo "DONE."
EOT

chmod +x add_build_connectivity_v012_replay.sh

echo "[7/7] Run v0.0.12 replay"

./add_build_connectivity_v012_replay.sh

echo "[v0.0.12] Git status"

git status
