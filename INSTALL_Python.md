# Installing Python for InCenter: step by step

InCenter does its audio processing in a small Python program. That means
your Mac or PC needs **Python 3** with one free add-on library, **NumPy**.
You only do this once. After that InCenter finds it automatically and you
never think about it again.

You do **not** need to know anything about Python. Just follow the steps
for your system and copy each command exactly.

---

## macOS

### Step 1: Install Python 3

1. Go to **https://www.python.org/downloads/macos/**
2. Download the latest **macOS 64-bit universal2 installer** (a `.pkg`
   file).
3. Open the `.pkg` and click through the installer (Continue → Agree →
   Install). Enter your Mac password if asked.

> Your Mac may already have a Python, but installing the one from
> python.org is the reliable path: it puts `python3` and `pip3` where
> InCenter expects them.

### Step 2: Open Terminal

Press **Cmd + Space**, type **Terminal**, press **Enter**. A window with a
text prompt opens. You'll paste commands here and press Enter after each.

### Step 3: Install NumPy

Copy this line, paste it into Terminal, press **Enter**:

```
python3 -m pip install --upgrade pip numpy
```

It will print a lot of text and may take a short while to finish. Wait
until the normal prompt comes back.

> **If you see a "permission denied" error**, run this instead. It
> installs just for your user and avoids touching system folders:
>
> ```
> python3 -m pip install --user --upgrade pip numpy
> ```

### Step 4: Check it worked

Paste this and press Enter:

```
python3 -c "import numpy; print('OK, InCenter is ready')"
```

If it prints **OK, InCenter is ready**, you're done. Close Terminal and use
InCenter normally.

---

## Windows

### Step 1: Install Python 3

1. Go to **https://www.python.org/downloads/windows/**
2. Download the latest **Windows installer (64-bit)** (a `.exe` file).
3. Run it. **On the first screen, tick the box at the bottom that says
   "Add python.exe to PATH".** Windows can't find Python later without
   this, so don't skip it.
4. Click **Install Now** and let it finish.

### Step 2: Open Command Prompt

Press the **Windows key**, type **cmd**, press **Enter**. A black window
with a text prompt opens.

### Step 3: Install NumPy

Copy this line, paste it in (right-click pastes in Command Prompt), press
**Enter**:

```
py -m pip install --upgrade pip numpy
```

Wait until it finishes and the prompt returns.

> **If `py` isn't recognized**, you probably missed the "Add to PATH"
> checkbox in Step 1. Re-run the installer, choose **Modify**, and make
> sure PATH is enabled, or just uninstall and reinstall with the box
> ticked.

### Step 4: Check it worked

Paste this and press Enter:

```
py -c "import numpy; print('OK, InCenter is ready')"
```

If it prints **OK, InCenter is ready**, you're done.

---

## Linux

Most distributions already have Python 3. Install the library with your
package manager or pip:

```
python3 -m pip install --user --upgrade pip numpy
```

Check:

```
python3 -c "import numpy; print('OK, InCenter is ready')"
```

---

## If InCenter still says "No Python 3 found"

InCenter searches the usual install locations automatically. If you have a
working Python 3 (with NumPy) but InCenter doesn't find it, it's
almost always because it lives somewhere unusual. Two ways to fix it:

**Easiest: reinstall from python.org.** Following Step 1 above installs
Python where InCenter already looks, so a fresh install from the official
installer is usually all it takes.

**Manual: point the script at it.** Find your Python's full path:

- macOS/Linux: `which python3`
- Windows: `where python`

Copy the path it prints. Then open `BudashAudio_InCenter.lua` in a text
editor and set the `PYTHON_OVERRIDE` line near the top to that path, e.g.:

```
local PYTHON_OVERRIDE = "/usr/local/bin/python3"
```

InCenter will then use exactly that interpreter.

---

## Already have Python?

If you use Python already (Homebrew, Anaconda, pyenv, etc.), you don't need
to install another one. Just make sure NumPy is available in it:

```
python3 -m pip install numpy
```

If InCenter doesn't auto-detect that interpreter, set its path via
`PYTHON_OVERRIDE` as described just above.
