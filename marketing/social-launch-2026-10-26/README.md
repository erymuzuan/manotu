# Manotu social launch kit

Open [index.html](index.html) for the Facebook and Instagram page concepts, platform-specific caption switcher and artwork downloads.

- [plan.md](plan.md): names, bios, About text, suggested handle (availability unverified), launch sequence and source-canvas copy corrections.
- [posts.md](posts.md): four complete Facebook/Instagram caption pairs and alt text.
- [posts.json](posts.json): structured captions.
- `assets/`: ten PNG exports and their editable SVG masters: avatar, Facebook cover, four feed posts and four highlight covers.

This is a design kit, not published social content. Names and URLs use Manotu; claims acknowledge early access and proprietary platform dependencies. Existing approved brand marks are reused without redrawing them.

Regenerate graphics with Python 3 and `rsvg-convert` (`build-assets.py`); regenerate the HTML and caption document with `build-preview.py`. The generator uses the repository's Nunito font and official brand masters. Preview from the repository root with a local HTTP server so the relative font and logo paths load.

Do not publish the place-link promotion until the fallback page and updated app are publicly available. The signed Android build was installed and tested locally on the owner's S24; website deployment is deferred at the owner's request.
