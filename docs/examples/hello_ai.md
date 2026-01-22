# hello_ai

Demonstrates AI agent integration with function calling capabilities.

## Source Code

**Path:** `examples/hello_ai/`

```zig
@include examples/hello_ai/src/main.zig
```

## Features Demonstrated

- AI client configuration
- Agent runtime and toolbox
- Function/tool registration
- Multi-step agent workflows
- Service dependencies and state management

## Prerequisites

This example requires a local LLM server. Example commands for starting one:

```sh
# Using llama-server with Qwen
llama-server -hf Qwen/Qwen3-8B-GGUF:Q8_0 --jinja --reasoning-format deepseek -ngl 99 -fa --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0

# Or with Gemma
llama-server --jinja -hf unsloth/gemma-3-4b-it-GGUF:Q4_K_XL
```

## Architecture

### Configuration

```zig
@include examples/hello_ai/src/main.zig#L7-L12
```

### Services

**MathService** - Basic arithmetic operations with usage tracking:
- `add(a, b)` - Add two numbers
- `mul(a, b)` - Multiply two numbers

**MailService** - Email message management:
- `listMessages(limit)` - List email messages

### Tool Registration

Tools are registered in an init hook:

```zig
@include examples/hello_ai/src/main.zig#L68-L73
```

## Example Tasks

The example runs two agent tasks:

### Task 1: Math Calculation and Email
```
"Can you tell how much is 12 * (32 + 4) and send the answer to foo@bar.com?"
```
The agent will:
1. Use `add` to calculate 32 + 4 = 36
2. Use `mul` to calculate 12 * 36 = 432
3. Use `sendMail` to send the result

### Task 2: Email Analysis
```
"Is there anything important in my mailbox? Show me table, sorted on priority"
```
The agent will:
1. Use `checkMailbox` to retrieve messages
2. Analyze and format them as a prioritized table

## Running

```sh
cd examples/hello_ai
zig build run
```

Make sure your LLM server is running first!

## How It Works

1. **Agent Creation**: Create an agent with specific tools
2. **Message Addition**: Add system and user messages
3. **Execution**: Call `agent.run()` which handles the tool calling loop
4. **Tool Calls**: The LLM decides which tools to call and when
5. **Results**: Final response is returned

## Key Concepts

- **AgentToolbox**: Registry of available tools
- **AgentRuntime**: Manages agent lifecycle and execution
- **Tool Functions**: Regular Zig functions exposed to the LLM
- **Automatic Serialization**: Parameters and results are automatically JSON-serialized

## Next Steps

- See [blog](./blog.md) for service layer patterns
- Check out the AI client documentation in the Reference section
