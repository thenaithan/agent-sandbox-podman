# Interactive prompt for agent-pod: [agent-pod] <path under /workspace> (branch) $
# The host ~/.bashrc is deliberately not sourced: it often exports tokens.
[[ $- == *i* ]] || return 0

__agent_pod_prompt() {
    local rel="${PWD#/workspace}" branch
    rel="${rel#/}"
    [[ "$PWD" == /workspace* ]] || rel="$PWD"
    branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
    PS1="\[\e[1;32m\][agent-pod]\[\e[0m\] \[\e[1;34m\]${rel:-.}\[\e[36m\]${branch:+ ($branch)}\[\e[0m\] \$ "
}
PROMPT_COMMAND=__agent_pod_prompt
