#!/usr/bin/env python
"""Graphical front end of make_chessbook_cli.py (tkinter, nothing to install beyond the venv).

    .venv/bin/python make_chessbook_gui.py

Pick the PDF, pick where to write the .chessbook, press Start. make_chessbook_cli.py runs as a child process; its progress lines
drive the progress bar of the current step and the overall step counter (step N of M, elapsed time)."""
import json
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from gui_i18n import LANGUAGES, LANGUAGE_NAMES, set_language, t

HERE = Path(__file__).parent
SETTINGS = HERE / "work" / "gui_settings.json"  # last folders and language, kept between runs (work/ is ignored by git)
# steps in the order make_chessbook_cli.py runs them (their durations differ too much between books for an overall percentage)
# (these labels are identifiers matching the '@@PROGRESS' lines of the CLI; the displayed text is t(key))
STEPS = ["Reading pages (OCR)", "Moves from diagrams", "Locating moves", "Reading diagrams"]
STEP_KEYS = dict(zip(STEPS, ("step_ocr", "step_moves", "step_locate", "step_diagrams")))
UI_CHOICES = (None,) + LANGUAGES  # combobox order: Automatic, English, Français, Español


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.minsize(640, 420)
        self.proc, self.lines, self.t0, self.stage = None, queue.Queue(), 0, 0
        self.status = ("idle",)  # what the step line shows, kept as data so a language change can redraw it
        self.settings = self.load_settings()
        self.ui_setting = self.settings.get("ui_lang") if self.settings.get("ui_lang") in LANGUAGES else None
        set_language(self.ui_setting)
        self.pdf, self.out, self.lang = tk.StringVar(), tk.StringVar(), tk.StringVar(value=self.settings.get("lang", "fr"))
        f = ttk.Frame(self, padding=12)
        f.pack(fill="both", expand=True)
        f.columnconfigure(1, weight=1)
        self.lbl_book, self.btn_pdf = ttk.Label(f), ttk.Button(f, command=self.pick_pdf)
        self.lbl_book.grid(row=0, column=0, sticky="w")
        ttk.Entry(f, textvariable=self.pdf).grid(row=0, column=1, sticky="ew", padx=6, pady=3)
        self.btn_pdf.grid(row=0, column=2)
        self.lbl_out, self.btn_out = ttk.Label(f), ttk.Button(f, command=self.pick_out)
        self.lbl_out.grid(row=1, column=0, sticky="w")
        ttk.Entry(f, textvariable=self.out).grid(row=1, column=1, sticky="ew", padx=6, pady=3)
        self.btn_out.grid(row=1, column=2)
        self.lbl_notation = ttk.Label(f)
        self.lbl_notation.grid(row=2, column=0, sticky="w")
        ttk.Combobox(f, textvariable=self.lang, values=("fr", "en"), state="readonly", width=5).grid(row=2, column=1, sticky="w", padx=6, pady=3)
        self.lbl_ui, self.ui_box = ttk.Label(f), ttk.Combobox(f, state="readonly", width=14)
        self.lbl_ui.grid(row=3, column=0, sticky="w")
        self.ui_box.grid(row=3, column=1, sticky="w", padx=6, pady=3)
        self.ui_box.bind("<<ComboboxSelected>>", self.on_ui_language)
        buttons = ttk.Frame(f)
        buttons.grid(row=4, column=0, columnspan=3, pady=8, sticky="w")
        self.start = ttk.Button(buttons, command=self.run)
        self.start.pack(side="left")
        self.stop = ttk.Button(buttons, command=self.cancel, state="disabled")
        self.stop.pack(side="left", padx=6)
        self.step_text, self.all_text = tk.StringVar(), tk.StringVar()
        ttk.Label(f, textvariable=self.step_text).grid(row=5, column=0, columnspan=3, sticky="w")
        self.step_bar = ttk.Progressbar(f, maximum=100)
        self.step_bar.grid(row=6, column=0, columnspan=3, sticky="ew", pady=(0, 6))
        ttk.Label(f, textvariable=self.all_text).grid(row=7, column=0, columnspan=3, sticky="w", pady=(0, 6))
        self.log = tk.Text(f, height=8, state="disabled", wrap="word")
        self.log.grid(row=9, column=0, columnspan=3, sticky="nsew")
        f.rowconfigure(9, weight=1)
        self.retranslate()
        self.after(100, self.poll)

    def retranslate(self):
        """Put every text in the current language (at start and when the language is changed)."""
        self.title(t("window_title"))
        for widget, key in ((self.lbl_book, "book"), (self.btn_pdf, "choose"), (self.lbl_out, "output"), (self.btn_out, "choose"),
                            (self.lbl_notation, "notation"), (self.lbl_ui, "ui_language"), (self.start, "start"), (self.stop, "cancel")):
            widget.configure(text=t(key))
        self.ui_box.configure(values=[t("auto")] + [LANGUAGE_NAMES[c] for c in LANGUAGES])
        self.ui_box.current(UI_CHOICES.index(self.ui_setting))
        self.show_status()
        self.show_overall(done=self.status[0] in ("done", "stopped"))

    def on_ui_language(self, _event=None):
        self.ui_setting = UI_CHOICES[self.ui_box.current()]
        set_language(self.ui_setting)
        self.settings.pop("ui_lang", None)
        self.remember(**({"ui_lang": self.ui_setting} if self.ui_setting else {}))
        self.retranslate()

    def show_status(self):
        kind = self.status[0]
        if kind == "idle":
            text = t("step")
        elif kind == "starting":
            text = t("starting")
        elif kind == "progress":
            _, label, i, n, note = self.status
            text = f"{t(STEP_KEYS[label]) if label in STEP_KEYS else label}: {i}/{n} {note}".strip()
        elif kind == "done":
            text = t("done")
        else:
            text = t("stopped", code=self.status[1])
        self.step_text.set(text)

    def load_settings(self):
        try:
            data = json.loads(SETTINGS.read_text())
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def remember(self, **values):
        self.settings.update(values)
        try:
            SETTINGS.parent.mkdir(parents=True, exist_ok=True)
            SETTINGS.write_text(json.dumps(self.settings, indent=1))
        except OSError:
            pass  # a read-only folder only costs the memory of the folders

    def folder(self, key, current=""):
        """Where a file dialog should open: the folder of the file already chosen, else the last one used, else the default."""
        for d in (Path(current).parent if current else None, Path(self.settings[key]) if key in self.settings else None):
            if d and d.is_dir():
                return str(d)
        return None

    def pick_pdf(self):
        path = filedialog.askopenfilename(title=t("pick_pdf"), filetypes=[("PDF", "*.pdf")], initialdir=self.folder("pdf_dir", self.pdf.get()))
        if path:
            self.pdf.set(path)
            self.remember(pdf_dir=str(Path(path).parent))
            if not self.out.get():  # propose the output in the last output folder, else next to the PDF
                out_dir = self.folder("out_dir") or str(Path(path).parent)
                self.out.set(str(Path(out_dir) / (Path(path).stem + ".chessbook")))

    def pick_out(self):
        path = filedialog.asksaveasfilename(title=t("pick_out"), defaultextension=".chessbook", filetypes=[("chessbook", "*.chessbook")],
                                            initialdir=self.folder("out_dir", self.out.get()),
                                            initialfile=Path(self.out.get()).name if self.out.get() else "")
        if path:
            self.out.set(path)
            self.remember(out_dir=str(Path(path).parent))

    def say(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def run(self):
        if not Path(self.pdf.get()).is_file() or not self.out.get():
            messagebox.showerror(t("missing_title"), t("missing_msg"))
            return
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")  # a new run starts with an empty log
        self.log.configure(state="disabled")
        cmd = [sys.executable, str(HERE / "make_chessbook_cli.py"), self.pdf.get(), "-o", self.out.get(), "--lang", self.lang.get(), "--progress-lines"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, cwd=HERE)
        threading.Thread(target=self.read, args=(self.proc,), daemon=True).start()
        self.remember(lang=self.lang.get(), pdf_dir=str(Path(self.pdf.get()).parent), out_dir=str(Path(self.out.get()).parent))
        self.t0 = time.time()
        self.start.configure(state="disabled")
        self.stop.configure(state="normal")
        self.step_bar["value"], self.stage = 0, 0
        self.show_overall()
        self.status = ("starting",)
        self.show_status()

    def read(self, proc):
        for line in proc.stdout:
            self.lines.put(line.rstrip("\n"))
        self.lines.put(None)  # end of output

    def cancel(self):
        if self.proc:
            self.proc.terminate()
            self.say(t("cancelled"))

    def show_overall(self, done=False):
        elapsed = int(time.time() - self.t0)
        clock = f"{elapsed // 60:02d}:{elapsed % 60:02d}"
        if self.stage and not done:
            self.all_text.set(t("overall_step", n=self.stage, total=len(STEPS), time=clock))
        else:
            self.all_text.set(t("overall_time", time=clock) if self.t0 else t("overall"))

    def progress(self, label, i, n, note):
        k = STEPS.index(label) if label in STEPS else None
        frac = i / max(1, n)
        self.step_bar["value"] = 100 * frac
        self.status = ("progress", label, i, n, note)
        self.show_status()
        if k is not None:
            self.stage = k + 1

    def poll(self):
        try:
            while True:
                line = self.lines.get_nowait()
                if line is None:
                    code = self.proc.wait()
                    self.start.configure(state="normal")
                    self.stop.configure(state="disabled")
                    if code == 0:
                        self.step_bar["value"] = 100
                        self.status = ("done",)
                    else:
                        self.status = ("stopped", code)
                    self.show_status()
                    self.show_overall(done=True)
                elif line.startswith("@@PROGRESS\t"):
                    _, label, i, n, note = line.split("\t")
                    self.progress(label, int(i), int(n), note)
                elif line.strip():
                    self.say(line)
        except queue.Empty:
            pass
        if self.proc and self.proc.poll() is None:
            self.show_overall()
        self.after(100, self.poll)


if __name__ == "__main__":
    App().mainloop()
