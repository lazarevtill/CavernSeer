# Taking a scan off the phone

Open a saved scan, choose the export icon and select **Backup ZIP (original +
mesh)**. Save to Files or AirDrop to your Mac. Backups are built locally; no
cloud account is required. Keep one verified copy off the phone, and keep a
second on a separate disk if the scan is hard to repeat. Do not delete your
phone copy until you have reopened the native scan and checked the mesh on
the Mac. A failed or cancelled export does not change the source scan.
Use **Original scan only** if a scan cannot produce a valid OBJ.

The ZIP contains these files (an enclosing folder may appear on extraction):

- `CavernSeer-….cavernseerscan`: byte-for-byte original. Reimport it into CavernSeer to
  recover saved survey stations, lines and snapshots, if present. Each export
  uses a unique name so multiple backup archives can be reimported.
- `mesh.obj`: portable triangle mesh, in meters, in local ARKit capture
  coordinates with +Y up. It contains geometry, not survey annotations,
  photos, per-frame depth samples, or a georeferenced map. Open it in
  Blender and check orientation and scale before aligning it with another
  scan or converting to GLB.
- `metadata.json`: date, native format version and export coordinate convention.
- `SHA256SUMS`: checksums of all three files. On the Mac, open Terminal in the
  extracted folder and run `shasum -a 256 -c SHA256SUMS`. A failed check means
  the copy should not be treated as your backup.

The native file may contain images and other sensitive context. Share only
with intended recipients. Some Files destinations sync online; choose local
storage or AirDrop if this material should stay offline.
