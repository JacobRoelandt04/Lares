"""One module per source; each fetches and parses API JSON and returns plain dicts.

No HTML-to-text here (htmltext.py owns that) and no state: the batch composes source, htmltext,
cleanup and intro.
"""
