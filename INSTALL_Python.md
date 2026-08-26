# Installing Python for InCenter — step by step

InCenter does its audio processing in a small Python program. That means
your Mac or PC needs **Python 3** with two free add-on libraries, **NumPy**
and **SciPy**. You only do this once. After that InCenter finds it
automatically and you never think about it again.

You do **not** need to know anything about Python. Just follow the steps
for your system, copying each command exactly.

---

## macOS

### Step 1 — Install Python 3

1. Go to **https://www.python.org/downloads/macos/**
2. Download the latest **macOS 64-bit universal2 installer** (a `.pkg`
   file).
3. Open the `.pkg` and click through the installer (Continue → Agree →
   Install). Enter your Mac password if asked.

> Your Mac may already have a Python, but installing the one from
> python.org is the reliable path — it puts `python3` and `pip3` where
> InCenter expects them.

### Step 2 — Open Terminal

Press **Cmd + Space**, type **Terminal**, press **Enter**. A window with a
text prompt opens. You'll paste commands here and press Enter after each.

### Step 3 — Install NumPy and SciPy

Copy this line, paste it into Terminal, press **Enter**:

```
python3 -m pip install --upgrade pip numpy scipy
```

It will print a lot of text and take a minute or two. Wait until the normal
prompt comes back.

> **If you see a "permission denied" error**, run this instead — it
> installs just for your user and avoids touching system folders:
>
> ```
> python3 -m pip install --user --upgrade pip numpy scipy
> ```

### Step 4 — Check it worked

Paste this and press Enter:

```
python3 -c "import numpy, scipy; print('OK, InCenter is ready')"
```

If it prints **OK, InCenter is ready**, you're done. Close Terminal and use
InCenter normally.

---

## Windows

### Step 1 — Install Python 3

1. Go to **https://www.python.org/downloads/windows/**
2. Download the latest **Windows installer (64-bit)** (a `.exe` file).
3. Run it. **On the first screen, tick the box at the bottom that says
   "Add python.exe to PATH".** This is the single most important step —
   without it, Windows can't find Python later.
4. Click **Install Now** and let it finish.

### Step 2 — Open Command Prompt

Press the **Windows key**, type **cmd**, press **Enter**. A black window
with a text prompt opens.

### Step 3 — Install NumPy and SciPy

Copy this line, paste it in (right-click pastes in Command Prompt), press
**Enter**:

```
py -m pip install --upgrade pip numpy scipy
```

Wait until it finishes and the prompt returns.

> **If `py` isn't recognized**, you probably missed the "Add to PATH"
> checkbox in Step 1. Re-run the installer, choose **Modify**, and make
> sure PATH is enabled — or just uninstall and reinstall with the box
> ticked.

### Step 4 — Check it worked

Paste this and press Enter:

```
py -c "import numpy, scipy; print('OK, InCenter is ready')"
```

If it prints **OK, InCenter is ready**, you're done.

---

## Linux

Most distributions already have Python 3. Install the two libraries with
your package manager or pip:

```
python3 -m pip install --user --upgrade pip numpy scipy
```

Check:

```
python3 -c "import numpy, scipy; print('OK, InCenter is ready')"
```

---

## If InCenter still says "No Python 3 found"

InCenter searches the usual install locations automatically. If you have a
working Python 3 (with NumPy and SciPy) but InCenter doesn't find it, it's
almost always because it lives somewhere unusual.

**Reinstall from python.org.** Following Step 1 above installs Python
where InCenter already looks, so a fresh install from the official
installer is usually all it takes.

There is currently no way to manually point InCenter at a non-standard
Python location — that option lived in a since-removed batch script and
went with it. If reinstalling doesn't fix detection, please open an issue
(see the repo's Credits & reporting section) rather than editing the
scripts by hand.

---

## Already have Python?

If you use Python already (Homebrew, Anaconda, pyenv, etc.), you don't need
to install another one — just make sure NumPy and SciPy are available in
it:

```
python3 -m pip install numpy scipy
```

If InCenter doesn't auto-detect that interpreter, see the note above —
there's currently no manual override; the fix is to also have (or link)
a Python in one of the auto-detected locations.
