import json
import random
from collections import Counter
from pathlib import Path


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SEED = 42
OUTPUT_DIR = Path("data/synthetic-payloads")

TARGETS = {
    "simple": {
        "size": 10 * 1024,              # 10 KB
        "depth": 2,
        "type_weights": {
            "string": 1.0,
        },
    },
    "moderate": {
        "size": 1 * 1024 * 1024,        # 1 MB
        "depth": 10,
        "type_weights": {
            "string": 1 / 3,
            "integer": 1 / 3,
            "float": 1 / 3,
        },
    },
    "complex": {
        "size": 10 * 1024 * 1024,       # 10 MB
        "depth": 15,
        "type_weights": {
            "string": 1 / 4,
            "integer": 1 / 4,
            "float": 1 / 4,
            "boolean": 1 / 4,
        },
    },
}

SIZE_TOLERANCE = 0.05


# ---------------------------------------------------------------------------
# Primitive value generation
# ---------------------------------------------------------------------------

def random_string(rng, length=32):
    """Generate a deterministic random ASCII string."""
    alphabet = (
        "abcdefghijklmnopqrstuvwxyz"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "0123456789"
    )

    return "".join(
        rng.choices(alphabet, k=length)
    )


def random_value(rng, value_type):
    """Generate one JSON-compatible primitive value."""

    if value_type == "string":
        return random_string(
            rng,
            rng.randint(20, 80)
        )

    if value_type == "integer":
        return rng.randint(
            0,
            1_000_000
        )

    if value_type == "float":
        return round(
            rng.uniform(0, 1_000_000),
            6
        )

    if value_type == "boolean":
        return rng.choice(
            [True, False]
        )

    raise ValueError(
        f"Unsupported JSON value type: {value_type}"
    )


# ---------------------------------------------------------------------------
# Type selection
# ---------------------------------------------------------------------------

def choose_value_type(rng, type_weights):
    """
    Select a JSON value type using the proportions specified
    in type_weights.
    """

    value_types = list(type_weights.keys())
    weights = list(type_weights.values())

    return rng.choices(
        value_types,
        weights=weights,
        k=1
    )[0]


# ---------------------------------------------------------------------------
# Nested record generation
# ---------------------------------------------------------------------------

def generate_record(rng, depth, type_weights):
    """
    Generate a nested JSON record.

    Each recursive level adds another object layer. Primitive
    values are placed at the deepest level.
    """

    if depth <= 1:
        return {
            f"field_{i}": random_value(
                rng,
                choose_value_type(
                    rng,
                    type_weights
                )
            )
            for i in range(5)
        }

    return {
        f"level_{depth}_{i}": generate_record(
            rng,
            depth - 1,
            type_weights
        )
        for i in range(2)
    }


# ---------------------------------------------------------------------------
# JSON serialisation
# ---------------------------------------------------------------------------

def serialise(payload):
    """
    Serialise JSON compactly.

    separators removes unnecessary whitespace so that the measured
    size corresponds to the compact representation used for comparison.
    """

    return json.dumps(
        payload,
        separators=(",", ":"),
        ensure_ascii=False
    )


def serialised_size(payload):
    """Return the compact serialised size in bytes."""

    return len(
        serialise(payload).encode("utf-8")
    )


# ---------------------------------------------------------------------------
# Depth and type analysis
# ---------------------------------------------------------------------------

def max_depth(value, current=0):
    """
    Calculate the maximum nesting depth of a JSON structure.
    """

    if isinstance(value, dict):
        if not value:
            return current + 1

        return max(
            max_depth(v, current + 1)
            for v in value.values()
        )

    if isinstance(value, list):
        if not value:
            return current + 1

        return max(
            max_depth(v, current + 1)
            for v in value
        )

    return current


def count_types(value, counts=None):
    """
    Count the number of occurrences of each JSON value type.
    """

    if counts is None:
        counts = Counter()

    if isinstance(value, dict):

        for child in value.values():
            count_types(child, counts)

    elif isinstance(value, list):

        for child in value:
            count_types(child, counts)

    elif value is None:

        counts["null"] += 1

    elif isinstance(value, bool):

        # bool must be checked before int because Python treats
        # booleans as a subclass of integers.
        counts["boolean"] += 1

    elif isinstance(value, int):

        counts["integer"] += 1

    elif isinstance(value, float):

        counts["float"] += 1

    elif isinstance(value, str):

        counts["string"] += 1

    return counts


# ---------------------------------------------------------------------------
# Payload generation
# ---------------------------------------------------------------------------

def generate_payload(level, seed=SEED):
    """
    Generate a payload for the requested complexity level.

    The structure is generated using the same procedure for every
    level. The target size is reached by adding records to the
    top-level object.
    """

    if level not in TARGETS:
        raise ValueError(
            f"Unknown payload level: {level}"
        )

    config = TARGETS[level]

    rng = random.Random(seed)

    target_size = config["size"]
    target_depth = config["depth"]
    type_weights = config["type_weights"]

    # Start with a nested structure that establishes the target depth.
    payload = {
        "root": generate_record(
            rng,
            target_depth - 1,
            type_weights
        )
    }

    # Add records until the payload reaches the lower bound.
    record_id = 0

    lower_bound = (
        target_size * (1 - SIZE_TOLERANCE)
    )

    while serialised_size(payload) < lower_bound:

        payload[f"record_{record_id}"] = generate_record(
            rng,
            target_depth - 1,
            type_weights
        )

        record_id += 1

    # If adding the final record pushed the payload above the
    # upper bound, remove records until it falls within the range.
    upper_bound = (
        target_size * (1 + SIZE_TOLERANCE)
    )

    while (
        serialised_size(payload) > upper_bound
        and record_id > 0
    ):

        record_id -= 1

        key = f"record_{record_id}"

        if key in payload:
            del payload[key]

    return payload


# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

def create_metadata(level, payload):
    """Create metadata describing the generated payload."""

    config = TARGETS[level]

    actual_size = serialised_size(payload)

    target_size = config["size"]

    lower_bound = (
        target_size * (1 - SIZE_TOLERANCE)
    )

    upper_bound = (
        target_size * (1 + SIZE_TOLERANCE)
    )

    return {
        "level": level,
        "seed": SEED,
        "target_size_bytes": target_size,
        "actual_size_bytes": actual_size,
        "size_error_percent": (
            (actual_size - target_size)
            / target_size
            * 100
        ),
        "within_5_percent": (
            lower_bound
            <= actual_size
            <= upper_bound
        ),
        "target_depth": config["depth"],
        "actual_max_depth": max_depth(payload),
        "type_counts": dict(
            count_types(payload)
        ),
    }


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def write_payload(level, payload):
    """Write the payload and its metadata to disk."""

    OUTPUT_DIR.mkdir(
        parents=True,
        exist_ok=True
    )

    payload_path = (
        OUTPUT_DIR / f"{level}.json"
    )

    metadata_path = (
        OUTPUT_DIR / f"{level}_metadata.json"
    )

    # Write compact JSON payload.
    with open(
        payload_path,
        "w",
        encoding="utf-8"
    ) as file:

        file.write(
            serialise(payload)
        )

    # Generate and write metadata.
    metadata = create_metadata(
        level,
        payload
    )

    with open(
        metadata_path,
        "w",
        encoding="utf-8"
    ) as file:

        json.dump(
            metadata,
            file,
            indent=2
        )

    return metadata


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_payload(level, metadata):
    """
    Validate that the generated payload satisfies the intended
    size and depth constraints.
    """

    config = TARGETS[level]

    target_size = config["size"]

    lower_bound = (
        target_size * (1 - SIZE_TOLERANCE)
    )

    upper_bound = (
        target_size * (1 + SIZE_TOLERANCE)
    )

    actual_size = metadata["actual_size_bytes"]

    if not (
        lower_bound
        <= actual_size
        <= upper_bound
    ):
        raise ValueError(
            f"{level} payload is outside ±5% size tolerance: "
            f"{actual_size:,} bytes"
        )

    if metadata["actual_max_depth"] != config["depth"]:
        raise ValueError(
            f"{level} payload has incorrect depth: "
            f"expected {config['depth']}, "
            f"got {metadata['actual_max_depth']}"
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():

    print(
        "Generating controlled JSON payloads..."
    )

    print(
        f"Seed: {SEED}"
    )

    for level in TARGETS:

        print(
            f"\nGenerating {level} payload..."
        )

        payload = generate_payload(
            level,
            seed=SEED
        )

        metadata = write_payload(
            level,
            payload
        )

        validate_payload(
            level,
            metadata
        )

        print(
            f"  Target size: "
            f"{metadata['target_size_bytes']:,} bytes"
        )

        print(
            f"  Actual size: "
            f"{metadata['actual_size_bytes']:,} bytes"
        )

        print(
            f"  Size error: "
            f"{metadata['size_error_percent']:.2f}%"
        )

        print(
            f"  Maximum depth: "
            f"{metadata['actual_max_depth']}"
        )

        print(
            f"  Type counts: "
            f"{metadata['type_counts']}"
        )

        print(
            "  ✓ Payload validated"
        )

    print(
        f"\nPayloads written to: {OUTPUT_DIR}"
    )


if __name__ == "__main__":
    main()