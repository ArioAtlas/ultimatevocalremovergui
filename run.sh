#!/bin/bash

# Set the conda environment name
ENV_NAME="uvr_env"

# Function to check if conda environment exists
conda_env_exists() {
    conda env list | grep -q "^${ENV_NAME} "
}

# Check if conda is available
if ! command -v conda &> /dev/null; then
    echo "Error: conda is not installed or not in PATH"
    exit 1
fi

# Create conda environment with Python 3.10 if it doesn't exist
if conda_env_exists; then
    echo "Conda environment '${ENV_NAME}' already exists. Skipping creation."
else
    echo "Creating conda environment '${ENV_NAME}' with Python 3.10..."
    conda create -n ${ENV_NAME} python=3.10 -y
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create conda environment"
        exit 1
    fi
    echo "Conda environment '${ENV_NAME}' created successfully."
fi

# Activate conda environment
echo "Activating conda environment '${ENV_NAME}'..."
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate ${ENV_NAME}

if [ $? -ne 0 ]; then
    echo "Error: Failed to activate conda environment"
    exit 1
fi

# Install dependencies from requirements.txt
echo "Installing dependencies from requirements.txt..."
LOG_FILE=$(mktemp)

# Handle sklearn deprecation issue (Dora package requires sklearn)
export SKLEARN_ALLOW_DEPRECATED_SKLEARN_PACKAGE_INSTALL=True

# Run pip install and show progress in real-time while also saving to log file
set +e  # Don't exit on error
pip install -r requirements.txt 2>&1 | tee "$LOG_FILE"
INSTALL_STATUS=${PIPESTATUS[0]}
set -e  # Re-enable exit on error

# If installation failed, try workarounds
if [ $INSTALL_STATUS -ne 0 ]; then
    # Check for playsound-specific error (more specific check)
    if grep -qi "Failed to build.*playsound\|ERROR.*playsound" "$LOG_FILE" && ! grep -qi "Requirement already satisfied.*playsound" "$LOG_FILE"; then
        echo ""
        echo "Detected playsound installation issue. Attempting workaround..."
        
        # Try installing older version that works (1.2.2)
        echo "Trying playsound version 1.2.2..."
        pip install playsound==1.2.2
        
        if [ $? -eq 0 ]; then
            echo "playsound installed successfully. Installing remaining packages..."
            pip install -r requirements.txt 2>&1 | tee "$LOG_FILE"
            INSTALL_STATUS=${PIPESTATUS[0]}
        else
            echo "playsound 1.2.2 also failed. Skipping playsound (it's optional for sound notifications)..."
            # Create a temporary requirements file without playsound
            grep -v "^playsound" requirements.txt > /tmp/requirements_no_playsound.txt
            echo "Installing remaining packages without playsound..."
            pip install -r /tmp/requirements_no_playsound.txt 2>&1 | tee "$LOG_FILE"
            INSTALL_STATUS=${PIPESTATUS[0]}
            rm -f /tmp/requirements_no_playsound.txt
        fi
    # Check for sklearn error (Dora dependency issue)
    elif grep -qi "Failed to build.*sklearn\|ERROR.*sklearn" "$LOG_FILE"; then
        echo ""
        echo "Detected sklearn installation issue. Installing scikit-learn first..."
        pip install scikit-learn
        if [ $? -eq 0 ]; then
            echo "Retrying installation with scikit-learn installed..."
            pip install -r requirements.txt 2>&1 | tee "$LOG_FILE"
            INSTALL_STATUS=${PIPESTATUS[0]}
        fi
    fi
fi

# Clean up temp file
rm -f "$LOG_FILE"

# Check if installation was successful
if [ $INSTALL_STATUS -eq 0 ]; then
    echo ""
    echo "Dependencies installed successfully."
    
    # Check for required system libraries and install via conda if needed
    echo "Checking for required system libraries..."
    
    # Function to check if a library exists
    check_library() {
        local lib_name=$1
        if ldconfig -p 2>/dev/null | grep -qi "$lib_name"; then
            return 0
        fi
        # Check common library paths
        for path in /usr/lib/x86_64-linux-gnu /usr/lib /usr/local/lib "$CONDA_PREFIX/lib"; do
            if [ -f "$path/lib${lib_name}.so" ] || [ -f "$path/lib${lib_name}.so.1" ]; then
                return 0
            fi
        done
        return 1
    }
    
    # Check and install libsndfile (required by soundfile)
    if ! check_library "sndfile"; then
        echo "libsndfile library not found. Installing via conda..."
        conda install -c conda-forge libsndfile -y
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to install libsndfile via conda."
            echo "Install manually: sudo apt-get install libsndfile1"
        fi
    fi
    
    # Check and install OpenGL libraries (required by pyglet)
    # Test if pyglet can actually load the libraries
    echo "Testing OpenGL library availability..."
    set +e  # Don't exit on error for this test
    python -c "from pyglet.gl.lib import link_GL, link_GLU" 2>&1
    GL_TEST=$?
    set -e  # Re-enable exit on error
    
    if [ $GL_TEST -eq 0 ]; then
        echo "✓ OpenGL libraries are available."
    else
        echo "✗ OpenGL libraries test failed."
        echo "OpenGL libraries not accessible to pyglet. Attempting to install..."
        
        # Try to install via system package manager
        INSTALLED=0
        if command -v apt-get &> /dev/null; then
            echo "Installing OpenGL libraries via apt-get..."
            sudo apt-get update -qq
            # Try newer package names first (for Ubuntu 20.04+)
            sudo apt-get install -y libglu1-mesa libgl1 2>&1 | grep -v "^$"
            INSTALL_STATUS=$?
            if [ $INSTALL_STATUS -ne 0 ]; then
                # Try alternative package names for older systems
                echo "Trying alternative package names..."
                sudo apt-get install -y libglu1-mesa libgl1-mesa-glx 2>&1 | grep -v "^$"
                INSTALL_STATUS=$?
            fi
            INSTALLED=$INSTALL_STATUS
        elif command -v yum &> /dev/null; then
            echo "Installing OpenGL libraries via yum..."
            sudo yum install -y mesa-libGLU mesa-libGL 2>&1 | grep -v "^$"
            INSTALLED=$?
        elif command -v pacman &> /dev/null; then
            echo "Installing OpenGL libraries via pacman..."
            sudo pacman -S --noconfirm glu mesa 2>&1 | grep -v "^$"
            INSTALLED=$?
        else
            INSTALLED=1
        fi
        
        if [ $INSTALLED -ne 0 ]; then
            echo ""
            echo "Warning: Failed to install OpenGL libraries automatically."
            echo "Please install them manually using your system package manager:"
            echo "  Ubuntu/Debian (20.04+): sudo apt-get install libglu1-mesa libgl1"
            echo "  Ubuntu/Debian (older): sudo apt-get install libglu1-mesa libgl1-mesa-glx"
            echo "  Fedora/RHEL: sudo yum install mesa-libGLU mesa-libGL"
            echo "  Arch: sudo pacman -S glu mesa"
            echo ""
            echo "After installing, you may need to run: sudo ldconfig"
            echo ""
            echo "Press Enter to continue anyway (will likely fail), or Ctrl+C to exit..."
            read
        else
            # Update library cache and test again
            sudo ldconfig 2>/dev/null || true
            echo "Verifying installation..."
            python -c "from pyglet.gl.lib import link_GL, link_GLU" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "Warning: Libraries installed but pyglet still cannot load them."
                echo "Try running: sudo ldconfig"
                echo "Or restart your terminal and run the script again."
                echo ""
                echo "Press Enter to continue anyway (will likely fail), or Ctrl+C to exit..."
                read
            else
                echo "✓ OpenGL libraries verified successfully!"
            fi
        fi
    fi
    
    # Check for ffmpeg (optional but recommended for pydub)
    if ! command -v ffmpeg &> /dev/null && ! command -v avconv &> /dev/null; then
        echo "ffmpeg not found. Installing ffmpeg for better audio support..."
        
        # Try to install via system package manager
        FFMPEG_INSTALLED=0
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y ffmpeg 2>&1 | grep -v "^$"
            FFMPEG_INSTALLED=$?
        elif command -v yum &> /dev/null; then
            sudo yum install -y ffmpeg 2>&1 | grep -v "^$"
            FFMPEG_INSTALLED=$?
        elif command -v pacman &> /dev/null; then
            sudo pacman -S --noconfirm ffmpeg 2>&1 | grep -v "^$"
            FFMPEG_INSTALLED=$?
        else
            FFMPEG_INSTALLED=1
        fi
        
        if [ $FFMPEG_INSTALLED -eq 0 ]; then
            echo "✓ ffmpeg installed successfully."
        else
            echo "Note: Failed to install ffmpeg automatically. Some audio features may be limited."
            echo "You can install it manually: sudo apt-get install ffmpeg"
        fi
    else
        echo "✓ ffmpeg is available."
    fi
    
    # Clear the screen
    clear
    # Run UVR.py
    echo "Starting UVR.py..."
    python UVR.py
else
    echo ""
    echo "Error: Failed to install dependencies. Please check the errors above."
    exit 1
fi

