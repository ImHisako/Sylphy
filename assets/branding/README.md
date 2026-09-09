# Sylphy artwork

The elf mascot was created with the built-in image generation tool, inspired by the supplied anime elf reference. The original generated mint backdrop was removed locally at the user's request; the exported PNG contains real alpha transparency.

- `sylphy-elf-source.png`: original generated artwork, retained for reproducibility.
- `sylphy-elf.png`: transparent master, used inside Flutter and to generate platform icons.

From the repository root, run:

```sh
dart run tool/remove_logo_background.dart
dart run tool/generate_app_icons.dart
```

The icon generator writes five Android launcher and monochrome notification density variants, a Windows ICO containing nine sizes (16–256 px), and a 512 px Linux PNG. All preserve transparency. Android launchers may apply their own icon backdrop or mask. The background-removal script also writes a light/dark review sheet to `build/branding/transparency-preview.png`.

## Generation prompt

Use case: logo-brand. Create a finished square app icon for Sylphy, a private messaging app for Android and desktop. Input image 1 is a character reference only, not an image to crop or reproduce as a screenshot. Design a new beautifully simple anime elf girl mascot inspired by her: short ivory-white bob with one small swooping forelock, clearly visible pointed elf ears, warm reddish amber eyes, tiny sapphire drop earrings, sage green high collar. Head and a little shoulder bust, facing mostly forward with a gentle friendly confident smile. Very clean bold dark evergreen outlines, flat vector-like colored shapes, minimal cel shading, restrained large facial features that remain readable at 32px. Crisp professional mascot logo, charming but not overly childish, no detailed costume or jewelry except simple collar and earrings. Composition: single centered mascot with all hair, ears and shoulders fully inside the central 62% of the square; balanced large head silhouette and generous even breathing room for Android circle/squircle masking. Solid uniform pale mint background #DFF3E8 extending edge to edge. No pre-rounded tile corners, no frame, no shadows on background, no scene, no extra symbols, no chat bubble, no words, letters, watermark or mockup. Output a single high resolution 1024x1024 square icon.

