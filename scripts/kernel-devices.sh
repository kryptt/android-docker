# Shared device -> kernel directory mapping.
# Sourced by both build.sh and setup.sh to avoid duplication.

declare -A KERNEL_DIRS=(
    [oneplus7pro]="kernel/sm8150"
    [oneplus8pro]="kernel/sm8250"
    [oneplus10pro]="kernel/sm8450"
)
