# Installation & Setup Guide

This guide covers building mlx-coder from source and setting up the required ML models.

## System Requirements

### Minimum Requirements
- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1, M2, M3, M4 or later)
- **10 GB free disk space** (for model + build artifacts)
- **16 GB RAM** recommended (8 GB minimum for 9B models)

### Development Requirements (for building from source)
- **Xcode 16+** (includes Swift 5.12+)
- **Git** for version control
- **Command Line Tools**: `xcode-select --install`

## Step 1: Clone the Repository

```bash
git clone https://github.com/your-user/mlx-coder.git
cd mlx-coder
```

## Step 2: Build the Project

### Using Xcode (Recommended)

```bash
# Build release binary
xcodebuild -scheme MLXCoder \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode
```

The binary will be at: `.build/xcode/Build/Products/Release/MLXCoder`

> **⚠️ Important**: You **must** use `xcodebuild`, not `swift build`, because MLX-Swift depends on Metal shader compilation (`.metallib` files) that only Xcode handles correctly.

### Using Swift Package Manager (Development)

For development and testing:

```bash
swift build
swift test
```

## Step 3: Set Up Models

mlx-coder requires a local MLX model. By default it looks in `~/models/Qwen/Qwen3.5-9B-4bit`.

### Option A: Download Pre-Converted Model (Recommended)

The Qwen 3.5 9B 4-bit model is pre-converted and ready to use:

```bash
# Create models directory
mkdir -p ~/models/Qwen

# Download the model (~5.5 GB)
cd ~/models/Qwen
git clone https://huggingface.co/mlx-community/Qwen3.5-9B-Instruct-4bit
mv Qwen3.5-9B-Instruct-4bit Qwen3.5-9B-4bit
```

**Alternative Models**:
- `Qwen2.5-7B-Instruct-4bit` (~4 GB, faster)
- `Llama-2-7B-4bit` (~4 GB)
- `Mistral-7B-4bit` (~4 GB)

Adjust paths accordingly in your commands or set `MODEL_PATH` environment variable.

### Option B: Convert Your Own Model

If you want to use a different model, convert it using MLX tools:

```bash
# Install MLX Python tools
pip install mlx-community

# Convert HuggingFace model
mlx_convert_model --model-name meta-llama/Llama-2-7b-chat-hf -q
# Output will be in ./mlx_model/
```

Then use with: `--model ./mlx_model`

## Step 4: Install System-Wide

Copy the built binary to a location in your `PATH`:

### Option A: System-Wide Installation

```bash
# Install binary
sudo cp .build/xcode/Build/Products/Release/MLXCoder /usr/local/bin/mlx-coder
chmod +x /usr/local/bin/mlx-coder

# Copy Metal shader bundle
sudo cp -R .build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle /usr/local/bin/
```

Verify:
```bash
which mlx-coder
mlx-coder --version  # Should print: 0.1.0
```

### Option B: User-Local Installation

```bash
# Create user bin directory
mkdir -p ~/.local/bin

# Install without sudo
cp .build/xcode/Build/Products/Release/MLXCoder ~/.local/bin/mlx-coder
cp -R .build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle ~/.local/bin/

# Add to PATH if not already there
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Verify
mlx-coder --version
```

### Option C: Development Use (No Installation)

Run directly from your build directory:

```bash
./.build/xcode/Build/Products/Release/MLXCoder chat --help
```

## Step 5: Quick Start

### Interactive Chat

```bash
mlx-coder chat
```

Should show the agent prompt. Try:
```
> What is 2+2?
> List files in current directory
> Explain the main.swift file
```

Type `exit` or `quit` to leave.

### Single Prompt

```bash
mlx-coder run --prompt "What is the weather in London?"
```

## Troubleshooting

### Build Issues

**Error**: `Failed to load the default metallib`
- **Cause**: Used `swift build` instead of `xcodebuild`
- **Solution**: Use `xcodebuild` command above

**Error**: `Xcode 16.0 or later is required`
- **Solution**: Update Xcode: `xcode-select --install` or via App Store

### Runtime Issues

**Error**: `Failed to load model at ~/models/Qwen/Qwen3.5-9B-4bit`
- **Solution**: Verify model exists: `ls ~/models/Qwen/Qwen3.5-9B-4bit`
- **Alternative**: Download model as described in Step 3

**Error**: `Out of memory`
- **Solution**: Use a smaller model (7B instead of 9B)
- **Try**: `--model ~/models/Qwen/Qwen2.5-7B-Instruct-4bit`

**Error**: `native-agent: command not found`
- **Solution**: Binary not in PATH
- **Fix**: Use full path `./.build/xcode/Build/Products/Release/MLXCoder`
- **Or install**: Follow Step 4 installation process

### Performance Issues

If responses are slow:

1. **Check RAM usage**: `top -l 1 | grep Mem`
   - Should be available RAM > model size
   
2. **Reduce token generation**: `--max-tokens 2048` (default 4096)

3. **Lower temperature**: `--temperature 0.3` (default 0.6)

4. **Use smaller model**: Switch to 7B instead of 9B model

5. **Reduce context**: Keep conversation shorter to reduce processing time

## Advanced Configuration

### Custom Model Path

```bash
mlx-coder chat --model ~/Downloads/my-model
```

### Custom Workspace

```bash
mlx-coder chat --workspace ~/my-project/src
```

### Advanced Generation Settings

```bash
mlx-coder chat \
  --model ~/models/Qwen/Qwen3.5-9B-4bit \
  --max-tokens 8192 \
  --temperature 0.7 \
  --top-p 0.9 \
  --top-k 50 \
  --repetition-penalty 1.1
```

See `mlx-coder chat --help` for all options.

### Environment Variables

```bash
# Set default model
export NATIVE_AGENT_MODEL=~/models/Qwen/Qwen3.5-9B-4bit

# Set default workspace
export NATIVE_AGENT_WORKSPACE=~/my-projects

# Set generation config
export NATIVE_AGENT_MAX_TOKENS=8192
export NATIVE_AGENT_TEMPERATURE=0.7
```

## Uninstallation

To remove mlx-coder:

```bash
# If system-wide installed
sudo rm /usr/local/bin/mlx-coder
sudo rm -R /usr/local/bin/mlx-swift_Cmlx.bundle

# If user-local installed
rm ~/.local/bin/mlx-coder
rm -R ~/.local/bin/mlx-swift_Cmlx.bundle

# Remove build artifacts
rm -rf .build/
```

Model files in `~/models/` are not automatically removed (you may want to keep them).

## Next Steps

- Read the [README](README.md) for usage examples
- Check [SECURITY.md](SECURITY.md) for security considerations
- See [CONTRIBUTING.md](CONTRIBUTING.md) if you want to contribute
- Explore tool documentation: `mlx-coder chat --tools`

## Getting Help

- **Issues**: [GitHub Issues](https://github.com/your-user/mlx-coder/issues)
- **Discussions**: [GitHub Discussions](https://github.com/your-user/mlx-coder/discussions)
- **Security**: See [SECURITY.md](SECURITY.md) for responsible disclosure

---

**Happy coding! 🎉**
