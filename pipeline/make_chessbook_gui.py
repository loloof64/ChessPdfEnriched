#!/usr/bin/env python
"""Graphical front end of make_chessbook_cli.py (tkinter, nothing to install beyond the venv).

    .venv/bin/python make_chessbook_gui.py

Pick the PDF, pick where to write the .chessbook, press Start. make_chessbook_cli.py runs as a child process; its progress lines
drive the two progress bars (current step, whole job)."""
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

HERE = Path(__file__).parent
# steps in the order make_chessbook_cli.py runs them, with their share of the whole job (a rough guess: only the bar's pace depends on it)
STEPS = [("Reading pages (OCR)", 25), ("Moves from diagrams", 15), ("Locating moves", 20), ("Reading diagrams", 40)]


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Chess PDF Enriched : make chessbook")
        self.minsize(640, 420)
        self.proc, self.lines, self.t0 = None, queue.Queue(), 0
        self.pdf, self.out, self.lang = tk.StringVar(), tk.StringVar(), tk.StringVar(value="fr")
        f = ttk.Frame(self, padding=12)
        f.pack(fill="both", expand=True)
        f.columnconfigure(1, weight=1)
        ttk.Label(f, text="Book (PDF)").grid(row=0, column=0, sticky="w")
        ttk.Entry(f, textvariable=self.pdf).grid(row=0, column=1, sticky="ew", padx=6, pady=3)
        ttk.Button(f, text="Choose…", command=self.pick_pdf).grid(row=0, column=2)
        ttk.Label(f, text="Output (.chessbook)").grid(row=1, column=0, sticky="w")
        ttk.Entry(f, textvariable=self.out).grid(row=1, column=1, sticky="ew", padx=6, pady=3)
        ttk.Button(f, text="Choose…", command=self.pick_out).grid(row=1, column=2)
        ttk.Label(f, text="Move language").grid(row=2, column=0, sticky="w")
        ttk.Combobox(f, textvariable=self.lang, values=("fr", "en"), state="readonly", width=5).grid(row=2, column=1, sticky="w", padx=6, pady=3)
        buttons = ttk.Frame(f)
        buttons.grid(row=3, column=0, columnspan=3, pady=8, sticky="w")
        self.start = ttk.Button(buttons, text="Start", command=self.run)
        self.start.pack(side="left")
        self.stop = ttk.Button(buttons, text="Cancel", command=self.cancel, state="disabled")
        self.stop.pack(side="left", padx=6)
        self.step_text, self.all_text = tk.StringVar(value="Step"), tk.StringVar(value="Whole job")
        ttk.Label(f, textvariable=self.step_text).grid(row=4, column=0, columnspan=3, sticky="w")
        self.step_bar = ttk.Progressbar(f, maximum=100)
        self.step_bar.grid(row=5, column=0, columnspan=3, sticky="ew", pady=(0, 6))
        ttk.Label(f, textvariable=self.all_text).grid(row=6, column=0, columnspan=3, sticky="w")
        self.all_bar = ttk.Progressbar(f, maximum=100)
        self.all_bar.grid(row=7, column=0, columnspan=3, sticky="ew", pady=(0, 6))
        self.log = tk.Text(f, height=8, state="disabled", wrap="word")
        self.log.grid(row=8, column=0, columnspan=3, sticky="nsew")
        f.rowconfigure(8, weight=1)
        self.after(100, self.poll)

    def pick_pdf(self):
        path = filedialog.askopenfilename(title="Choose the PDF", filetypes=[("PDF", "*.pdf")])
        if path:
            self.pdf.set(path)
            if not self.out.get():
                self.out.set(str(Path(path).with_suffix(".chessbook")))

    def pick_out(self):
        path = filedialog.asksaveasfilename(title="Write the .chessbook to", defaultextension=".chessbook", filetypes=[("chessbook", "*.chessbook")],
                                            initialfile=Path(self.out.get()).name if self.out.get() else "")
        if path:
            self.out.set(path)

    def say(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def run(self):
        if not Path(self.pdf.get()).is_file() or not self.out.get():
            messagebox.showerror("Missing file", "Choose an existing PDF and an output file.")
            return
        cmd = [sys.executable, str(HERE / "make_chessbook_cli.py"), self.pdf.get(), "-o", self.out.get(), "--lang", self.lang.get(), "--progress-lines"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, cwd=HERE)
        threading.Thread(target=self.read, args=(self.proc,), daemon=True).start()
        self.t0 = time.time()
        self.start.configure(state="disabled")
        self.stop.configure(state="normal")
        self.step_bar["value"] = self.all_bar["value"] = 0
        self.step_text.set("Starting (loading the models, can take a minute)…")

    def read(self, proc):
        for line in proc.stdout:
            self.lines.put(line.rstrip("\n"))
        self.lines.put(None)  # end of output

    def cancel(self):
        if self.proc:
            self.proc.terminate()
            self.say("Cancelled.")

    def progress(self, label, i, n, note):
        k = next((k for k, (name, _) in enumerate(STEPS) if name == label), None)
        frac = i / max(1, n)
        self.step_bar["value"] = 100 * frac
        self.step_text.set(f"{label}: {i}/{n} {note}".strip())
        if k is not None:
            total = sum(w for _, w in STEPS)
            done = sum(w for _, w in STEPS[:k]) + STEPS[k][1] * frac
            self.all_bar["value"] = 100 * done / total

    def poll(self):
        try:
            while True:
                line = self.lines.get_nowait()
                if line is None:
                    code = self.proc.wait()
                    self.start.configure(state="normal")
                    self.stop.configure(state="disabled")
                    elapsed = int(time.time() - self.t0)
                    if code == 0:
                        self.step_bar["value"] = self.all_bar["value"] = 100
                        self.step_text.set("Done")
                    else:
                        self.step_text.set(f"Stopped (exit code {code})")
                    self.all_text.set(f"Whole job: {elapsed // 60:02d}:{elapsed % 60:02d}")
                elif line.startswith("@@PROGRESS\t"):
                    _, label, i, n, note = line.split("\t")
                    self.progress(label, int(i), int(n), note)
                elif line.strip():
                    self.say(line)
        except queue.Empty:
            pass
        if self.proc and self.proc.poll() is None:
            elapsed = int(time.time() - self.t0)
            self.all_text.set(f"Whole job: {elapsed // 60:02d}:{elapsed % 60:02d}")
        self.after(100, self.poll)


if __name__ == "__main__":
    App().mainloop()
