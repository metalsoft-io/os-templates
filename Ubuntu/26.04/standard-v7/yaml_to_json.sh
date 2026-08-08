#!/bin/bash

# Convert template.yaml to template.json, applying MetalSoft schema fixups:
#   * Keys listed in FORCE_STRING_KEYS are emitted as JSON strings using their
#     literal YAML text, so versions like 26.04 or 24.10 keep their exact form
#     instead of becoming floats (24.10 would otherwise become 24.1).
#   * Lowercase keys in RENAME_KEYS are rewritten to camelCase (bootmode ->
#     bootMode, mimetype -> mimeType, etc).
#   * Each entry under templateAssets gets templateId: 0.
#   * Each entry under templateAssets.file gets contentBase64, the base64
#     encoding of the local file named by file.name, resolved relative to the
#     input YAML's directory.
#
# Usage: ./yaml_to_json.sh [input_file] [output_file]

INPUT_FILE="${1:-template.yaml}"
OUTPUT_FILE="${2:-template.json}"

# Keys whose scalar values must stay strings in the JSON output.
FORCE_STRING_KEYS="version"

# Check if input file exists
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: Input file '$INPUT_FILE' not found."
    exit 1
fi

if python3 -c "import yaml" &> /dev/null; then
    FORCE_STRING_KEYS="$FORCE_STRING_KEYS" python3 - "$INPUT_FILE" "$OUTPUT_FILE" <<'PY'
import json
import os
import sys
import base64

import yaml
from yaml.constructor import SafeConstructor

force_string_keys = set(os.environ.get("FORCE_STRING_KEYS", "").split())
constructor = SafeConstructor()
NULL_TAG = "tag:yaml.org,2002:null"


# Lowercase YAML keys that must be camelCased in the JSON output.
RENAME_KEYS = {
    "bootmode": "bootMode",
    "drivetype": "driveType",
    "readymethod": "readyMethod",
    "sshport": "sshPort",
    "passwordtype": "passwordType",
    "mimetype": "mimeType",
    "templatingengine": "templatingEngine",
    "templateassets": "templateAssets",
    "imagebuild": "imageBuild",
}


def build(node, as_string=False):
    if isinstance(node, yaml.MappingNode):
        result = {}
        for key_node, value_node in node.value:
            key = build(key_node)
            if isinstance(key, str):
                key = RENAME_KEYS.get(key, key)
            result[key] = build(value_node, as_string=key in force_string_keys)
        return result
    if isinstance(node, yaml.SequenceNode):
        return [build(item) for item in node.value]
    # Scalar: keep the literal YAML text so numeric-looking values keep their form.
    if as_string and node.tag != NULL_TAG:
        return node.value
    return constructor.construct_object(node, deep=True)


input_file, output_file = sys.argv[1], sys.argv[2]

with open(input_file) as f:
    root = yaml.compose(f)

data = {} if root is None else build(root)

# Every template asset carries templateId: 0, and its file gets contentBase64
# from the local file looked up by file.name next to the input YAML.
if isinstance(data, dict):
    asset_dir = os.path.dirname(os.path.abspath(input_file))
    for asset in data.get("templateAssets") or []:
        if isinstance(asset, dict):
            asset.setdefault("templateId", 0)
            file_obj = asset.get("file")
            if isinstance(file_obj, dict):
                file_name = file_obj.get("name")
                # Assets sourced from a URL (e.g. downloaded ISOs) are not
                # embedded as base64; they're fetched at build time instead.
                if file_name and not file_obj.get("url"):
                    local_path = os.path.join(asset_dir, file_name)
                    if not os.path.isfile(local_path):
                        print(
                            f"Error: asset file '{file_name}' not found at '{local_path}'.",
                            file=sys.stderr,
                        )
                        sys.exit(1)
                    with open(local_path, "rb") as bf:
                        file_obj["contentBase64"] = base64.b64encode(bf.read()).decode("ascii")

with open(output_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
else
    echo "Error: PyYAML is required for conversion."
    echo "Install via: pip3 install pyyaml"
    exit 1
fi

if [[ $? -eq 0 ]]; then
    echo "Successfully converted '$INPUT_FILE' to '$OUTPUT_FILE'"
else
    echo "Error: Conversion failed."
    exit 1
fi
