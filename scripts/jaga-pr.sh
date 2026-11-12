#!/usr/bin/env bash
# Penjaga PR: memeriksa seluruh PR terbuka lalu memvalidasi, mengomentari, menutup,
# atau meng-merge-nya tanpa perlu ada manusia. Berjalan berkala, jadi tidak bergantung
# pada run workflow dari fork (yang butuh persetujuan untuk akun baru).
#
# Aturan merge otomatis:
#   1. Validasi file klaim lolos.
#   2. Semua berkas yang berubah ada di data/domains/ atau data/emails/.
#   3. Field domain, subdomain, owner, address tidak berubah dari versi main.
#   4. `owner` di setiap berkas sama persis dengan penulis PR. Tanpa pengecualian.
#   5. Akun penulis memang ada di GitHub.
#
# Dijalankan oleh pr-jaga.yml lewat jadwal dan workflow_dispatch, TIDAK lewat
# pull_request. Bukan selera: workflow yang dipicu pull_request dari fork selalu
# menerima token baca-saja, sekalipun `permissions:` menulis `write` dan setelan repo
# juga `write`. Log run membuktikannya: "Contents: read / Issues: read /
# PullRequests: read". Dengan izin itu bot tidak bisa berkomentar, menutup, apalagi
# merge, sehingga setiap PR dari kontributor baru menggantung tanpa penjelasan.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

BEKU="domain subdomain owner address"
# Penanda ditulis di komentar bot. Dipakai untuk memastikan bot tidak berkomentar
# berulang kali, TETAPI tetap menulis ulang bila pesannya sudah tidak sesuai lagi.
# Penanda beda untuk tiap sebab, jadi perubahan aturan tidak meninggalkan pesan basi.
MARK_DITOLAK="<!-- jaga-pr:ditolak -->"
MARK_TINJAU="<!-- jaga-pr:tinjau -->"

git config --global --add safe.directory "$PWD" 2>/dev/null || true
git fetch -q origin main || exit 1
BASE=$(git rev-parse origin/main)

komentar() { gh pr comment "$1" --body "$2" >/dev/null 2>&1 || true; }

sudah_komentar() {
  gh pr view "$1" --json comments -q '.comments[].body' 2>/dev/null | grep -qF "$2"
}

# Akun palsu atau yang sudah dihapus tidak boleh lolos hanya karena namanya sama
# dengan yang tercatat sebagai owner.
akun_ada() {
  [ -n "$1" ] && gh api "users/$1" --jq .login >/dev/null 2>&1
}

mapfile -t DAFTAR < <(gh pr list --state open --limit 100 --json number -q '.[].number' 2>/dev/null)
echo "PR terbuka: ${#DAFTAR[@]}"

for n in "${DAFTAR[@]}"; do
  INFO=$(gh pr view "$n" --json isDraft,author,headRefName,headRepositoryOwner 2>/dev/null) || continue
  [ "$(echo "$INFO" | jq -r '.isDraft')" = "true" ] && continue
  AUTHOR=$(echo "$INFO" | jq -r '.author.login')
  REF=$(echo "$INFO" | jq -r '.headRefName')
  PEMILIK_HEAD=$(echo "$INFO" | jq -r '.headRepositoryOwner.login // empty')
  echo "--- PR #$n oleh $AUTHOR (head: $PEMILIK_HEAD:$REF)"

  if ! akun_ada "$AUTHOR"; then
    echo "    akun penulis tidak ada di GitHub, PR ditutup"
    komentar "$n" "PR ini ditutup karena akun GitHub \`$AUTHOR\` tidak ditemukan. Klaim hanya bisa diajukan dari akun yang benar-benar ada."
    gh pr close "$n" >/dev/null 2>&1 || true
    continue
  fi

  if ! git fetch -q origin "pull/$n/head" 2>/dev/null; then
    echo "    gagal mengambil head, dilewati"
    continue
  fi
  HEAD_SHA=$(git rev-parse FETCH_HEAD)
  MB=$(git merge-base "$BASE" "$HEAD_SHA")
  git checkout -q --detach "$HEAD_SHA" 2>/dev/null || continue

  # 1. Validasi memakai skrip versi main, bukan versi dari PR.
  git show "$BASE:scripts/validate.mjs" > /tmp/validate.mjs 2>/dev/null || exit 0
  if ! node /tmp/validate.mjs "$MB" > /tmp/validate.log 2>&1; then
    echo "    validasi gagal, PR ditutup"
    {
      cat /tmp/validate.log
      echo
      echo "Validasi gagal, jadi PR ini ditutup otomatis. Perbaiki berkasnya sesuai catatan di atas, lalu buka PR baru. Perubahan tidak akan pernah aktif lewat PR ini."
    } > /tmp/balasan.md
    komentar "$n" "$(cat /tmp/balasan.md)"
    gh pr close "$n" >/dev/null 2>&1 || true
    continue
  fi

  # 2. Periksa berkas dan kepemilikan.
  BOLEH=1
  SEBAB=""
  HAPUS=0
  BERUBAH=$(git diff --name-only "$MB" "$HEAD_SHA")
  for f in $BERUBAH; do
    case "$f" in
      data/domains/*.json|data/emails/*.json) ;;
      *) BOLEH=0; SEBAB="ada berkas di luar data/: $f"; continue ;;
    esac
    if [ ! -f "$f" ]; then
      # Berkas dihapus. Ini boleh kalau pemiliknya sendiri yang menghapus, dan
      # hanya untuk berkas SUBDOMAIN. Berkas mailbox tidak boleh dihapus lewat
      # PR, karena menghapus akun email tidak bisa dikembalikan.
      case "$f" in
        data/emails/*)
          BOLEH=0; SEBAB="berkas mailbox $f tidak boleh dihapus lewat PR"
          continue
          ;;
      esac
      LAMA_HAPUS=$(git show "$BASE:$f" 2>/dev/null || true)
      if [ -z "$LAMA_HAPUS" ]; then
        BOLEH=0; SEBAB="berkas $f dihapus, padahal tidak ada di main"; continue
      fi
      OWNER_HAPUS=$(echo "$LAMA_HAPUS" | jq -r '.owner // ""' 2>/dev/null)
      # Owner kosong atau gagal dibaca berarti tidak bisa dipastikan pemiliknya.
      # Tanpa pagar ini, penulis PR yang namanya juga kosong akan lolos.
      if [ -z "$OWNER_HAPUS" ] || [ -z "$AUTHOR" ]; then
        BOLEH=0; SEBAB="pemilik $f tidak bisa dipastikan, penghapusan ditolak"
        continue
      fi
      if [ "$(echo "$OWNER_HAPUS" | tr '[:upper:]' '[:lower:]')" != "$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')" ]; then
        BOLEH=0; SEBAB="berkas $f milik $OWNER_HAPUS, bukan $AUTHOR"
      fi
      HAPUS=1
      continue
    fi
    OWNER=$(jq -r '.owner // ""' "$f" 2>/dev/null)
    if [ -z "$OWNER" ] || [ -z "$AUTHOR" ]; then
      BOLEH=0; SEBAB="pemilik $f tidak bisa dipastikan, perubahan ditolak"; continue
    fi
    if [ "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')" ]; then
      BOLEH=0; SEBAB="berkas $f tercatat atas nama $OWNER, bukan $AUTHOR"; continue
    fi
    LAMA=$(git show "$BASE:$f" 2>/dev/null || true)
    if [ -n "$LAMA" ]; then
      for k in $BEKU; do
        a=$(echo "$LAMA" | jq -r --arg k "$k" '.[$k] // ""')
        b=$(jq -r --arg k "$k" '.[$k] // ""' "$f")
        if [ "$a" != "$b" ]; then BOLEH=0; SEBAB="field $k pada $f berubah ($a -> $b)"; fi
      done
    fi
  done

  if [ "$BOLEH" -eq 0 ]; then
    echo "    ditolak: $SEBAB"
    if ! sudah_komentar "$n" "$MARK_DITOLAK"; then
      komentar "$n" "$MARK_DITOLAK
PR ini ditolak: $SEBAB

Aturannya sederhana: yang boleh mengubah isi berkas klaim hanya akun GitHub yang tercatat sebagai \`owner\` di berkas itu. Ini yang mencegah orang lain mengambil alih klaim bukan miliknya.

Catatan soal menghapus klaim:
- Boleh menghapus klaim **subdomain** milikmu sendiri. Berkasnya hilang dari main, dan record DNS-nya ikut dibersihkan oleh sinkronisasi.
- Berkas **mailbox tidak boleh dihapus lewat PR**, karena menghapus akun email tidak bisa dikembalikan. Ajukan lewat issue kalau memang perlu.

Kalau kamu memang pemiliknya tetapi memakai akun berbeda, kirim ulang dari akun yang sama dengan \`owner\`. Kalau \`owner\` di berkas itu salah catat, tulis di issue supaya dibetulkan pemelihara.

PR ini ditutup dan perubahan di dalamnya tidak akan pernah aktif. Kalau salah satu poin di atas tidak jelas, tulis di issue."
    fi
    gh pr close "$n" >/dev/null 2>&1 || true
    continue
  fi

  # 3. Semua aman, merge.
  if gh pr merge "$n" --squash >/dev/null 2>&1 || gh pr merge "$n" --squash --admin >/dev/null 2>&1; then
    SHA=$(gh pr view "$n" --json mergeCommit -q '.mergeCommit.oid[0:7]' 2>/dev/null)
    echo "    di-merge otomatis ($SHA)"
    komentar "$n" "Validasi lolos dan berkas yang berubah tercatat atas namamu, jadi PR ini di-merge otomatis ($SHA). Perubahan aktif setelah sinkronisasi berikutnya."
  else
    echo "    merge gagal (mungkin sudah ditangani jalur lain)"
  fi
done

git checkout -q "$BASE" 2>/dev/null || git checkout -q main 2>/dev/null || true
echo "Selesai."
