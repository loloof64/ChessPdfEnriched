"""Interface texts of make_chessbook_gui.py in English, French and Spanish.

    .venv/bin/python gui_i18n.py      # self-check

`set_language(setting)`: setting is "en", "fr", "es" or None/anything else = Automatic (the system language, English when unsupported)."""
import locale
import os
import string

LANGUAGES = ("en", "fr", "es")
LANGUAGE_NAMES = {"en": "English", "fr": "Français", "es": "Español"}  # never translated


def _s(en, fr, es):
    return {"en": en, "fr": fr, "es": es}


STRINGS = {
    "window_title": _s("Chess PDF Enriched : make chessbook", "Chess PDF Enriched : créer un chessbook", "Chess PDF Enriched : crear un chessbook"),
    "book": _s("Book (PDF)", "Livre (PDF)", "Libro (PDF)"),
    "choose": _s("Choose…", "Choisir…", "Elegir…"),
    "output": _s("Output (.chessbook)", "Sortie (.chessbook)", "Salida (.chessbook)"),
    "notation": _s("Book move notation", "Notation des coups du livre", "Notación de jugadas del libro"),
    "ui_language": _s("Interface language", "Langue de l'interface", "Idioma de la interfaz"),
    "auto": _s("Automatic", "Automatique", "Automático"),
    "start": _s("Start", "Démarrer", "Iniciar"),
    "cancel": _s("Cancel", "Annuler", "Cancelar"),
    "step": _s("Step", "Étape", "Paso"),
    "overall": _s("Overall", "Global", "Total"),
    "overall_time": _s("Overall: {time}", "Global : {time}", "Total: {time}"),
    "overall_step": _s("Overall: step {n} of {total}, {time}", "Global : étape {n} sur {total}, {time}", "Total: paso {n} de {total}, {time}"),
    "starting": _s("Starting (loading the models, can take a minute)…", "Démarrage (chargement des modèles, cela peut prendre une minute)…",
                   "Iniciando (cargando los modelos, puede tardar un minuto)…"),
    "done": _s("Done", "Terminé", "Terminado"),
    "stopped": _s("Stopped (exit code {code})", "Arrêté (code de sortie {code})", "Detenido (código de salida {code})"),
    "cancelled": _s("Cancelled.", "Annulé.", "Cancelado."),
    "missing_title": _s("Missing file", "Fichier manquant", "Archivo faltante"),
    "missing_msg": _s("Choose an existing PDF and an output file.", "Choisissez un PDF existant et un fichier de sortie.",
                      "Elija un PDF existente y un archivo de salida."),
    "pick_pdf": _s("Choose the PDF", "Choisir le PDF", "Elegir el PDF"),
    "pick_out": _s("Write the .chessbook to", "Écrire le .chessbook dans", "Escribir el .chessbook en"),
    "step_ocr": _s("Reading pages (OCR)", "Lecture des pages (OCR)", "Lectura de páginas (OCR)"),
    "step_moves": _s("Moves from diagrams", "Coups depuis les diagrammes", "Jugadas desde los diagramas"),
    "step_locate": _s("Locating moves", "Localisation des coups", "Localización de jugadas"),
    "step_diagrams": _s("Reading diagrams", "Lecture des diagrammes", "Lectura de diagramas"),
}

_language = None  # None = Automatic


def detect(env=None, locale_name=None):
    """System language among LANGUAGES, "en" when unsupported or unknown. Same order of variables as gettext."""
    env = os.environ if env is None else env
    name = (env.get("LANGUAGE") or "").split(":")[0] or next((env[k] for k in ("LC_ALL", "LC_MESSAGES", "LANG") if env.get(k)), "")
    if not name and locale_name is None and env is os.environ:
        try:
            name = locale.getlocale()[0] or ""
        except (ValueError, TypeError):
            name = ""
    name = name or locale_name or ""
    code = name[:2].lower()
    return code if code in LANGUAGES else "en"


def set_language(setting):
    global _language
    _language = setting if isinstance(setting, str) and setting in LANGUAGES else None


def current():
    return _language or detect()


def t(key, **fmt):
    return STRINGS[key][current()].format(**fmt)


def _selfcheck():
    for key, texts in STRINGS.items():
        assert set(texts) == set(LANGUAGES), key
        fields = {tuple(sorted(f for _, f, _, _ in string.Formatter().parse(x) if f)) for x in texts.values()}
        assert len(fields) == 1, f"placeholders differ in {key}: {fields}"
    for env, want in [({"LANG": "fr_CA.UTF-8"}, "fr"), ({"LANG": "es_MX"}, "es"), ({"LANG": "en_GB"}, "en"), ({"LANG": "pt_BR"}, "en"),
                      ({"LANG": "C"}, "en"), ({"LANG": "POSIX"}, "en"), ({"LANG": ""}, "en"), ({"LANGUAGE": "es:en", "LANG": "fr_FR"}, "es"),
                      ({"LC_ALL": "fr_FR", "LANG": "es_ES"}, "fr")]:
        assert detect(env=env) == want, (env, detect(env=env))
    assert detect(env={}, locale_name=None) == "en"
    assert detect(env={}, locale_name="es_ES") == "es"
    for bad in ("de", 5, None, ""):
        set_language(bad)
        assert _language is None
    set_language("es")
    assert t("start") == STRINGS["start"]["es"]
    assert "2" in t("overall_step", n=2, total=4, time="01:05") and "01:05" in t("overall_step", n=2, total=4, time="01:05")
    set_language(None)
    print("gui_i18n self-check ok")


if __name__ == "__main__":
    _selfcheck()
