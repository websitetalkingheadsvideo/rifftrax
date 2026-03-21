---
name: item-image-generator
description: Generate and wire up item images for Valley by Night admin items using 速推AI + style_agent and the Supabase-based tools in this repo.
---

## When to Use This Skill

- You are working on the Valley by Night project and:
  - Need to generate or fix images for items in the admin panel.
  - See broken item thumbnails or \"No image\" placeholders on `admin/item_portraits.php` or `admin/admin_items.php`.
  - Are asked to \"generate item images\" or \"fill in missing equipment art\".

This skill gives you a **deterministic pipeline** to:

1. Detect items missing images.
2. Generate base renders with 速推AI.
3. Apply consistent styling via `style_agent`.
4. Save images into `uploads/Items`.
5. Update the `items.image` column in Supabase.

## Key Files & Tools

- Scanner (missing images):
  - `tools/repeatable/php/data-tools/scan_missing_item_images.php`
- DB updater for image filenames:
  - `tools/repeatable/php/data-tools/generate_item_images.php`
- Style & prompt reference:
  - `reference/Items/ImageStyle.md`
- Serving path used by the admin UI:
  - `admin/serve_item_image.php` → loads `uploads/Items/{filename}`
- Admin views that should show the images:
  - `admin/admin_items.php`
  - `admin/item_portraits.php`

## Art Direction & Prompts (速推AI + style_agent)

Always follow the style rules in `reference/Items/ImageStyle.md`. In short:

- **Canvas**: Square 1:1, 1024×1024.
- **Background**: Pure white, no props, no vignette.
- **Subject**: Single item, centered, side or slight 3/4 view, full silhouette visible.
- **Lighting**: Neutral studio, soft shadows, realistic materials.
- **Naming**: Lowercase slug of item name with underscores, e.g. `.38 Revolver` → `38_revolver.jpg`.

### Base Prompt Template (速推AI, 1994‑locked)

When calling 速推AI to generate the base render, use this pattern (fill in `{ITEM_NAME}` and `{ITEM_TYPE}` from the item row).  
**Era lock:** everything must look like it exists in Phoenix, Arizona in **1994 or earlier** – no post‑1994 designs, logos, or tech.

```text
Square 1:1 item render, 1024×1024, ultra clear, isolated on pure white background, no text, no watermark.
Game-ready inventory icon for a modern gothic horror tabletop RPG.
Set in Phoenix, Arizona in 1994. No designs, logos, technology, materials, or weapon styling from after 1994.
Subject: {ITEM_NAME} ({ITEM_TYPE}).
Side view or slight 3/4 angle, centered, full silhouette visible with a little white space around it.
Neutral studio lighting, soft shadow directly under the item, high detail, realistic materials, no stylized outlines or dramatic lighting.
Avoid: futuristic weapons, modern 2000s+ gun styling, red-dot sights, Picatinny rails, LED lights, holographic sights, sci-fi polymer shapes, modern branding, HUDs, UI icons, or overlays.
```

Example for `.38 Revolver`:

```text
Square 1:1 item render, 1024×1024, ultra clear, isolated on pure white background, no text, no watermark.
Game-ready inventory icon for a modern gothic horror tabletop RPG.
Set in Phoenix, Arizona in 1994. No designs, logos, technology, materials, or weapon styling from after 1994.
Subject: .38 Revolver (Weapon) — compact snub-nose revolver, brushed steel, black rubber grip, modern for the early 1990s but not futuristic.
Side view, centered, full silhouette visible with a little white space around it.
Neutral studio lighting, soft shadow directly under the gun, high detail, realistic materials, no stylized outlines or dramatic lighting.
Avoid: futuristic handguns, 2000s+ tactical pistol designs, red-dot sights, Picatinny rails, laser modules, LED lights, holographic sights, sci-fi polymer shapes, modern branding, HUDs, UI icons, or overlays.
```

### style_agent Usage

After you get the base image from 速推AI:

1. Call the `project-0-v:-style-agent` MCP tools to retrieve the relevant art rules if needed:
   - `getRules`
   - `getPrompts`
2. Apply the Valley by Night item inventory style:
   - If there is a concrete profile ID, use it (e.g. `vbn_item_inventory_v1`).
   - Otherwise, pass a style hint such as:

```text
Match Valley by Night item inventory art: clean white background, medium contrast, realistic materials, no text, no border, no vignette.
```

The styled output should still be 1024×1024 and ready to downscale to 512×512 for the admin UI.

## End-to-End Workflow (Single Item, e.g. .38 Revolver)

When the user asks you to generate art for a specific item (like the `.38 Revolver`), follow this sequence:

1. **Discover the item row**
   - Use the Supabase MCP (project-0-v:-supabase) or existing PHP APIs to find the item in the `items` table (id, name, type, current `image` value).
2. **Generate base image with 速推AI**
   - Call the 速推AI MCP (if configured) with the base prompt template above.
   - Ensure the model outputs a square 1024×1024 PNG/JPG on white.
3. **Apply style via style_agent**
   - Send the base image to `style_agent` with the Valley by Night item style configuration.
4. **Save the file into `uploads/Items`**
   - Compute the slug from the item name using the convention in `reference/Items/ImageStyle.md`:
     - Example: `.38 Revolver` → `38_revolver.jpg`.
   - Save the styled image as:
     - `uploads/Items/38_revolver.jpg`
5. **Update the DB**
   - Run:
     - `php tools/repeatable/php/data-tools/generate_item_images.php --id={ITEM_ID}`
   - This script will:
     - Look for `uploads/Items/38_revolver.jpg`.
     - Update `items.image` to `38_revolver.jpg` if the file exists.
6. **Verify**
   - Load `admin/item_portraits.php` and confirm the `.38 Revolver` card now shows the new image via `serve_item_image.php?file=38_revolver.jpg`.

## Batch Workflow (All Missing Items)

When asked to \"generate images for all missing items\", orchestrate this pipeline:

1. **Scan for missing images**
   - Run:
     - `php tools/repeatable/php/data-tools/scan_missing_item_images.php --format=json`
   - Parse the JSON output to get the list of items where:
     - `status` is `missing` (no filename), or
     - `status` is `missing_file` (filename set but file not present).
2. **Generate images per item**
   - For each missing item (respecting a reasonable batch size, e.g. 5–10 at a time):
     - Build the 速推AI prompt from `reference/Items/ImageStyle.md` using the item’s `name` and `type`.
     - Call 速推AI to get a 1024×1024 base image.
     - Pipe the image through `style_agent` to enforce consistent style.
     - Compute the slug and filename, e.g. ` kevlar_vest.jpg`, `ancient_sword.jpg`, etc.
     - Save each styled image into `uploads/Items/{slug}.jpg`.
3. **Update DB filenames**
   - After a batch of images is saved, run:
     - `php tools/repeatable/php/data-tools/generate_item_images.php --all-missing --limit=N`
   - This script:
     - Detects items whose image file is absent or filename is empty.
     - For each, computes the slug from the name and expects `{slug}.jpg` to exist in `uploads/Items`.
     - Updates `items.image` accordingly (unless `--dry-run` is used).
4. **Repeat until clean**
   - Re-run the scanner:
     - `php tools/repeatable/php/data-tools/scan_missing_item_images.php --format=text`
   - Continue batches until it reports zero missing/broken images, or only known exceptions.

## Safety & Constraints

- Do **not** delete any files or database rows in this pipeline.
- Never silently invent fallback filenames; if no reasonable slug can be derived, stop and report the problem.
- If SUPABASE_URL / keys are missing and PHP tools fail, you must tell the user to configure `.env` as described in `includes/supabase_client.php` docs before proceeding.
- Respect the project-wide rule that portraits and item renders are **square 1:1, 1024×1024** in prompts.

## What to Report Back to the User

When using this skill in a session, summarize:

- How many items were detected as missing/broken.
- For each processed item: id, name, generated filename.
- Any items you skipped because 速推AI/style_agent failed or the file could not be saved.
- How to rerun the batch (exact CLI commands used).

