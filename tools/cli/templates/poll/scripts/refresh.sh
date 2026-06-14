#!/bin/zsh
# Poll command: the host runs this every `refresh.everySeconds` and parses stdout.
# parse.kind:"json" means: print ONE JSON object whose keys match your fields'
# refreshKey. Keep it fast and side-effect-free — it runs on a timer forever.
print -r -- "{\"time\":\"$(date +%H:%M:%S)\",\"load\":\"$(uptime | sed 's/.*load averages*: //')\"}"
