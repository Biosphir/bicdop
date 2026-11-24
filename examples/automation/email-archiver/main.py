"""Simulation only. No mailbox connections or message deletion."""

import json
from time import monotonic

GIB = 1024 ** 3
MIB = 1024 ** 2
MAILBOXES = [
    {"quota_fraction": 0.94, "messages_oldest_first": [260, 320, 410, 90, 30]},
    {"quota_fraction": 0.42, "messages_oldest_first": [240, 180]},
    {"quota_fraction": 0.98, "messages_oldest_first": [560, 380, 90, 40]},
]


def main():
    started = monotonic()
    processed = archived = 0
    for index, mailbox in enumerate(MAILBOXES, 1):
        if mailbox["quota_fraction"] < 0.90:
            print(f"Mailbox {index}: under quota threshold", flush=True)
            continue
        batch = 0
        for message_size in mailbox["messages_oldest_first"]:
            batch += message_size * MIB
            if batch >= GIB:
                break
        if batch:
            processed += 1
            archived += batch
        print(f"Mailbox {index}: simulated {batch} archived bytes", flush=True)
    report = {
        "schema": 1,
        "metrics": {
            "mailboxes_checked": len(MAILBOXES),
            "mailboxes_processed": processed,
            "archived_bytes": archived,
            "duration_seconds": monotonic() - started,
            "errors": 0,
        },
    }
    print("BICDOP_RESULT " + json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
