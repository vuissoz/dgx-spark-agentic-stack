#!/usr/bin/env python3
import json
import re
import uuid
import xml.etree.ElementTree as ET
from typing import Any


PSEUDO_FUNCTION_BLOCK_RE = re.compile(
    r"<function=([A-Za-z0-9_.:-]+)>(.*?)</function>", re.IGNORECASE | re.DOTALL
)
PSEUDO_PARAMETER_RE = re.compile(
    r"<parameter=([A-Za-z0-9_.:-]+)>\s*(.*?)\s*</parameter>", re.IGNORECASE | re.DOTALL
)
GENERIC_XML_TOOL_BLOCK_RE = re.compile(
    r"<([A-Za-z_][A-Za-z0-9_.:-]*)>(.*?)</\1>", re.IGNORECASE | re.DOTALL
)
XML_TOOL_WRAPPER_TAGS = {"tool_call", "tool_calls", "tools"}


def json_dumps_compact(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def normalize_tool_arguments(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list, int, float, bool)) or value is None:
        return json_dumps_compact(value)
    return "{}"


def allowed_tool_names(tools: Any) -> set[str] | None:
    if not isinstance(tools, list) or not tools:
        return None

    names: set[str] = set()
    for item in tools:
        if not isinstance(item, dict):
            continue
        function = item.get("function")
        if not isinstance(function, dict):
            continue
        name = function.get("name")
        if isinstance(name, str) and name.strip():
            names.add(name.strip())
    return names or None


def _tool_allowed(name: str, allowed_names: set[str] | None) -> bool:
    if not name.strip():
        return False
    if allowed_names is None:
        return True
    return name.strip() in allowed_names


def _xml_node_to_value(node: ET.Element) -> Any:
    children = list(node)
    if not children:
        return "".join(node.itertext()).strip()

    result: dict[str, Any] = {}
    for child in children:
        key = child.tag.strip()
        if not key:
            continue
        value = _xml_node_to_value(child)
        existing = result.get(key)
        if existing is None:
            result[key] = value
        elif isinstance(existing, list):
            existing.append(value)
        else:
            result[key] = [existing, value]
    return result


def _tool_calls_from_xml_element(node: ET.Element, allowed_names: set[str] | None) -> list[dict[str, Any]]:
    tag = node.tag.strip()
    if not tag:
        return []

    if tag.lower() in XML_TOOL_WRAPPER_TAGS:
        tool_calls: list[dict[str, Any]] = []
        for child in list(node):
            tool_calls.extend(_tool_calls_from_xml_element(child, allowed_names))
        return tool_calls

    children = list(node)
    if not children or not _tool_allowed(tag, allowed_names):
        return []

    arguments_obj: dict[str, Any] = {}
    for child in children:
        key = child.tag.strip()
        if not key:
            continue
        value = _xml_node_to_value(child)
        existing = arguments_obj.get(key)
        if existing is None:
            arguments_obj[key] = value
        elif isinstance(existing, list):
            existing.append(value)
        else:
            arguments_obj[key] = [existing, value]

    if not arguments_obj:
        return []

    return [
        {
            "id": f"call_{uuid.uuid4().hex[:24]}",
            "type": "function",
            "function": {
                "name": tag,
                "arguments": normalize_tool_arguments(arguments_obj),
            },
        }
    ]


def pseudo_tool_calls_from_content(content: str, tools: Any = None) -> tuple[str, list[dict[str, Any]] | None]:
    if not isinstance(content, str) or not content:
        return "", None

    allowed_names = allowed_tool_names(tools)
    normalized: list[dict[str, Any]] = []
    cleaned = content
    legacy_found = False
    generic_found = False

    if "<function=" in content and "<parameter=" in content:
        for match in PSEUDO_FUNCTION_BLOCK_RE.finditer(content):
            name = match.group(1).strip()
            body = match.group(2)
            if not _tool_allowed(name, allowed_names):
                continue

            arguments_obj: dict[str, str] = {}
            for param in PSEUDO_PARAMETER_RE.finditer(body):
                param_name = param.group(1).strip()
                param_value = param.group(2).strip()
                if not param_name:
                    continue
                arguments_obj[param_name] = param_value

            normalized.append(
                {
                    "id": f"call_{uuid.uuid4().hex[:24]}",
                    "type": "function",
                    "function": {
                        "name": name,
                        "arguments": normalize_tool_arguments(arguments_obj),
                    },
                }
            )
            legacy_found = True

        if legacy_found:
            cleaned = PSEUDO_FUNCTION_BLOCK_RE.sub("", cleaned)

    if "<" in content and "</" in content:
        for match in GENERIC_XML_TOOL_BLOCK_RE.finditer(content):
            block = match.group(0)
            try:
                root = ET.fromstring(block)
            except ET.ParseError:
                continue
            parsed = _tool_calls_from_xml_element(root, allowed_names)
            if parsed:
                generic_found = True
                normalized.extend(parsed)

        if generic_found:
            cleaned = GENERIC_XML_TOOL_BLOCK_RE.sub("", cleaned)

    if not normalized:
        return content, None

    cleaned = re.sub(r"</?tool_call>", "", cleaned, flags=re.IGNORECASE)
    cleaned = cleaned.strip()
    return cleaned, normalized
