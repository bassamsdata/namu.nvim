# NAMU.NVIM - Development Guide

## Build & Test Commands
```bash
# Run all tests
make test

# Run a specific test file
make test_file FILE=tests/test_selecta.lua

# Install dependencies
make deps

# Clean dependencies
make clean
```

## Code Style Guidelines
- **Formatting**: Use Lua style with 2-space indentation
- **Imports**: Use `require("namu.module")` format
- **Naming**:
  - Functions use snake_case (e.g., `get_symbols()`)
  - Variables use snake_case (e.g., `local current_item`)
  - Modules use snake_case (e.g., `namu_symbols`)
- **Error Handling**: Use pcall for capturing errors from external APIs
- **Documentation**: Add docstrings for public functions with `---@param` and `---@return` annotations
- **Testing**: Write tests in Lua files ending with `_test.lua` using the mini.test framework

## RULES:
- Don't create any summary documents or README documents unless it's explicitly requested.
- Always do `make format` before commit or push any file.


- Visually test UI changes before merging. Leave feature changes unmerged until the user has reviewed them visually and explicitly requests the merge.
