package totp

import "../../web"
import "core:crypto"
import "core:crypto/aead"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:sync"
import "core:time"
import "../../buffer"
import "../../http"
import "../common"
import "../auth"

/*
TOTP (RFC 6238) second factor: the algorithm, the enrollment state and its
storage. `totp_auth.odin` builds the two-stage login on top of this; nothing
here knows about HTTP.

Why the state file and not the session: the shared secret is the second
factor's root of trust. Putting it in the session cookie would hand it to
the client (the payload is base64, signed but readable) and a stolen cookie
would then be enough to clone the authenticator. So the secret lives on the
server, encrypted with a master key that comes from the configuration, and
the cookie only ever carries "this session passed the second factor".

Crypto choices:

  - HOTP/TOTP use HMAC-SHA1, because that is what every authenticator app
    implements. SHA-1 is broken for collision resistance, not for HMAC, and
    RFC 6238 keeps it as the default. `core:crypto` exposes it as
    `.Insecure_SHA1` so the choice is visible at the call site.
  - secrets are stored with ChaCha20-Poly1305 (`core:crypto/aead`) rather
    than a hand-rolled XOR keystream: the tag is what stops a tampered
    state file from turning into "any code verifies".
  - comparisons of attacker-supplied values go through `secure_eq` (from
    `auth.odin`), so a rejected code costs the same time wherever it
    differs.

Threat model, stated plainly: this protects an account whose password
leaked. It does not protect against a compromised server, because the
master key is on that server; keep the state file and the master key out of
the same backup, and rotate the account if either leaks.
*/

// Algorithm parameters. The defaults are what authenticator apps assume.
TOTP_DIGITS          :: 6
TOTP_PERIOD_SECS     :: 30
TOTP_SKEW            :: 1 // accept the previous and the next window
TOTP_MAX_ATTEMPTS    :: 5
TOTP_LOCK_SECS       :: 15 * 60
TOTP_BACKUP_CODES    :: 10
TOTP_SECRET_BYTES    :: 20 // RFC 4226 section 4: 160 bits
TOTP_MASTER_KEY_BYTES :: 32

// DEFAULT_TOTP_ISSUER is what the authenticator app shows above the account
// when `Totp_Config.issuer` is empty.
DEFAULT_TOTP_ISSUER :: "web"

// TOTP_ENCRYPTION_AAD is the associated data the secret is sealed with. It
// is constant on purpose: it binds the ciphertext to "this is a TOTP
// secret", so a blob copied out of another field of the same file does not
// open.
TOTP_ENCRYPTION_AAD :: "web/totp/secret/v1"

// Totp_Error is the outcome of every operation. `.None` is success; the
// rest are specific enough for a UI to say something useful ("that code is
// used", "too many attempts") instead of a generic 401.
Totp_Error :: enum {
	None,
	Bad_Master_Key,      // secret_hex is not 32 bytes of hex
	Not_Setup,           // no enrollment for this user
	Not_Enabled,         // enrolled but not confirmed yet
	Already_Enabled,     // re-enrolling an active account (disable first)
	Invalid_Code,
	Code_Already_Used,   // replay of a code accepted earlier
	Account_Locked,      // too many failures; wait out lock_secs
	Invalid_Backup_Code,
	Crypto_Failure,      // decryption or rand failure
	Storage_Failure,     // the state file could not be written
}

/*
Totp_Config configures one Totp instance.

`secret_hex` is the master key: 64 hex characters, exactly what
`openssl rand -hex 32` prints. An empty or malformed one is refused at init
instead of silently storing secrets in clear - a 2FA that quietly does
nothing is worse than no 2FA.

`path` is the JSON state file. Empty means memory only, which is what tests
and single-process demos want; a real deployment wants a file on a
directory only the service can read, so the secrets survive restarts.

`allocator` defaults to `context.allocator` at init time and is used for
every long-lived allocation (state, keys, strings), so `totp_destroy` frees
exactly what init and the setters allocated. Do not move the instance across
allocators.
*/
Totp_Config :: struct {
	issuer:            string, // shown by the app, e.g. "example.com"
	secret_hex:        string, // 32-byte master key, 64 hex chars; required
	path:              string, // JSON state file; "" = memory only
	digits:            int,    // default TOTP_DIGITS
	period_secs:       int,    // default TOTP_PERIOD_SECS
	skew:              int,    // default TOTP_SKEW (windows each side)
	max_attempts:      int,    // default TOTP_MAX_ATTEMPTS, 0 = never lock
	lock_secs:         int,    // default TOTP_LOCK_SECS
	backup_code_count: int,    // default TOTP_BACKUP_CODES
	allocator:         mem.Allocator,
}

// Totp_Binding is one user's enrollment. `locked_until` and
// `failed_attempts` are the brute-force budget, kept per user and persisted
// so a restart does not reset it.
Totp_Binding :: struct {
	secret_enc:      string,
	enabled:         bool,
	failed_attempts: int,
	locked_until:    i64, // unix seconds; 0 = unlocked
	created_at:      i64,
	updated_at:      i64,
}

// Totp_Backup_Code is one single-use recovery code, stored as a hash
// (HMAC keyed with the master key over the user id and the code), never in
// clear.
Totp_Backup_Code :: struct {
	code_hash: string,
	used:      bool,
}

// Totp_Used_Code remembers an accepted code so it cannot be replayed inside
// the window it is still valid in. `window` is the matched counter, not the
// current one: with skew, the same digits stay valid for up to
// (2 * skew + 1) windows and must be refused in every one of them.
Totp_Used_Code :: struct {
	window:  i64,
	code:    string,
	used_at: i64,
}

// Totp_State is the whole on-disk state, keyed by user id. Maps rather than
// slices because every operation is a lookup by user; the file itself is
// still a flat JSON object, so an operator can read it.
Totp_State :: struct {
	bindings: map[string]Totp_Binding,
	backups:  map[string][]Totp_Backup_Code,
	used:     map[string][]Totp_Used_Code,
}

/*
Totp is the second-factor store. One instance is shared by every connection
and every acceptor thread, so all of it sits behind `mu`: TOTP runs once per
login, and serialising it is cheaper than reasoning about a lock-free
cache. `totp_init` / `totp_destroy` are not safe to call twice or
concurrently with requests - they belong to startup and shutdown.
*/
Totp :: struct {
	master_key:   [32]byte,
	issuer:       string,
	path:         string,
	digits:       int,
	period:       int,
	skew:         int,
	max_attempts: int,
	lock_secs:    int,
	backup_count: int,
	alloc:        mem.Allocator,
	state:        Totp_State,
	mu:           sync.Mutex,
	initialized:  bool,
	// load_failed records a state file that exists but could not be parsed.
	// Starting empty would silently turn 2FA off for every account, so the
	// caller is expected to check `totp_load_failed` at startup and refuse
	// to serve rather than overwrite the file.
	load_failed:  bool,
}

// totp_load_failed reports a state file that existed but could not be read
// or parsed. A missing file (first run) is not a failure.
totp_load_failed :: proc(t: ^Totp) -> bool {
	return t != nil && t.load_failed
}

// Totp_Enrollment is what a setup page needs to render once: the base32
// secret for manual entry, the otpauth:// URI (which a QR code encodes), and
// the recovery codes. All three are handed to the caller's allocator, so a
// handler can pass the request arena and forget about them.
Totp_Enrollment :: struct {
	secret:       string,
	otpauth_uri:  string,
	backup_codes: []string,
}

// Totp_Status answers "is 2FA on for this user", for a settings page.
Totp_Status :: struct {
	enabled:      bool,
	has_binding:  bool,
	locked:       bool,
	backup_codes: int, // unused codes left
}

// ---------------------------------------------------------------------------
// init / destroy
// ---------------------------------------------------------------------------

totp_init :: proc(t: ^Totp, cfg: Totp_Config) -> Totp_Error {
	if t == nil {
		return .Bad_Master_Key
	}
	t^ = Totp{}

	key, key_ok := totp_hex_decode_key(cfg.secret_hex)
	if !key_ok {
		return .Bad_Master_Key
	}
	t.master_key = key

	alloc := cfg.allocator
	if alloc.procedure == nil {
		alloc = context.allocator
	}
	t.alloc = alloc

	issuer := cfg.issuer
	if len(issuer) == 0 {
		issuer = DEFAULT_TOTP_ISSUER
	}
	t.issuer = buffer.clone_string(issuer, alloc)
	t.path = buffer.clone_string(cfg.path, alloc)

	t.digits = totp_default_positive(cfg.digits, TOTP_DIGITS)
	if t.digits > 8 {
		// 10^9 exceeds what the 31-bit truncation can produce, and no app
		// implements more than 8 digits.
		t.digits = 8
	}
	t.period = totp_default_positive(cfg.period_secs, TOTP_PERIOD_SECS)
	// 0 = unset (take the TOTP_SKEW default), negative = strict. Accepting
	// the neighbour windows is what makes a phone whose clock is a few
	// seconds off still work, so "0 means unset" is the safe reading.
	t.skew = cfg.skew
	if t.skew == 0 {
		t.skew = TOTP_SKEW
	}
	if t.skew < 0 {
		t.skew = 0
	}
	if t.skew > 10 {
		t.skew = 10
	}
	t.max_attempts = cfg.max_attempts
	if t.max_attempts < 0 {
		t.max_attempts = 0
	}
	t.lock_secs = totp_default_positive(cfg.lock_secs, TOTP_LOCK_SECS)
	t.backup_count = totp_default_positive(cfg.backup_code_count, TOTP_BACKUP_CODES)

	t.state = totp_state_make(alloc)
	totp_state_load(t)
	t.initialized = true
	return .None
}

// totp_destroy releases the state, the strings and the mutex. Call it after
// the server has stopped: a request touching a destroyed instance reads
// freed memory.
totp_destroy :: proc(t: ^Totp) {
	if t == nil || !t.initialized {
		return
	}
	alloc := t.alloc
	totp_state_destroy(&t.state, alloc)
	delete(t.issuer, alloc)
	delete(t.path, alloc)
	crypto.zero_explicit(&t.master_key, size_of(t.master_key))
	t^ = Totp{}
}

// totp_issuer returns the issuer string shown by authenticator apps.
totp_issuer :: proc(t: ^Totp) -> string {
	if t == nil || !t.initialized {
		return ""
	}
	return t.issuer
}

// ---------------------------------------------------------------------------
// enrollment
// ---------------------------------------------------------------------------

/*
totp_setup starts enrollment: it generates a fresh secret, stores it
(disabled until confirmed) and returns the material the user has to keep.

The binding stays disabled until `totp_confirm` sees a valid code, so a
half-finished setup never turns into "2FA required but the secret was never
scanned". Calling it again replaces an unconfirmed binding; on an *active*
one it refuses with `.Already_Enabled` - re-enrolling is how an attacker
with a stolen session would take the account over, so the caller has to ask
for the current code first (`totp_verify`) and then `totp_disable`.
*/
totp_setup :: proc(
	t: ^Totp,
	user: string,
	allocator := context.allocator,
) -> (Totp_Enrollment, Totp_Error) {
	enrollment := Totp_Enrollment{}
	if t == nil || !t.initialized || len(user) == 0 {
		return enrollment, .Not_Setup
	}

	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)

	if old, exists := t.state.bindings[user]; exists && old.enabled {
		return enrollment, .Already_Enabled
	}

	secret_raw: [TOTP_SECRET_BYTES]byte
	crypto.rand_bytes(secret_raw[:])
	secret := totp_base32_encode(secret_raw[:], allocator)

	enc, enc_ok := totp_encrypt_secret(secret, t.master_key, t.alloc)
	if !enc_ok {
		return enrollment, .Crypto_Failure
	}

	codes := totp_generate_backup_codes(t.backup_count, allocator)
	hashes := make([]Totp_Backup_Code, len(codes), t.alloc)
	for code, i in codes {
		hashes[i] = Totp_Backup_Code{code_hash = totp_hash_backup_code(t, user, code, t.alloc)}
	}

	now := time.to_unix_seconds(time.now())
	totp_binding_store(t, user, Totp_Binding {
		secret_enc   = enc,
		enabled      = false,
		created_at   = now,
		updated_at   = now,
	})
	totp_backups_store(t, user, hashes)

	if !totp_state_save(t) {
		// The write failed. The caller gets no enrollment (the secret it
		// never saw is useless), and the pending binding stays in memory
		// only: a retry overwrites it, `totp_destroy` frees it, and nothing
		// reached the disk.
		totp_free_backup_codes(codes, allocator)
		delete(secret, allocator)
		return enrollment, .Storage_Failure
	}

	enrollment.secret = secret
	enrollment.otpauth_uri = totp_otpauth_uri(secret, user, t.issuer, allocator)
	enrollment.backup_codes = codes
	return enrollment, .None
}

// totp_confirm turns a pending binding on, once the user has proven that the
// secret made it into their app.
totp_confirm :: proc(t: ^Totp, user, code: string) -> Totp_Error {
	if t == nil || !t.initialized {
		return .Not_Setup
	}
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)

	b, ok := t.state.bindings[user]
	if !ok {
		return .Not_Setup
	}
	if b.enabled {
		return .Already_Enabled
	}
	now := time.to_unix_seconds(time.now())
	if totp_lockout_active(t, &b, now) {
		return .Account_Locked
	}
	secret, secret_ok := totp_decrypt_secret(b.secret_enc, t.master_key, t.alloc)
	if !secret_ok {
		return .Crypto_Failure
	}
	defer delete(secret, t.alloc)

	if matched, _ := totp_match_code(secret, code, t, time.now()); !matched {
		// same budget as a login: the enrollment page is reachable with the
		// password alone, so guessing here has to be just as expensive
		totp_record_failure(t, user, b, now)
		return .Invalid_Code
	}

	b.enabled = true
	b.failed_attempts = 0
	b.locked_until = 0
	b.updated_at = time.to_unix_seconds(time.now())
	t.state.bindings[user] = b
	if !totp_state_save(t) {
		return .Storage_Failure
	}
	return .None
}

// totp_disable turns the second factor off. The caller is expected to have
// verified the password *and* the current code; this function cannot tell.
totp_disable :: proc(t: ^Totp, user: string) -> Totp_Error {
	if t == nil || !t.initialized {
		return .Not_Setup
	}
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)

	b, ok := t.state.bindings[user]
	if !ok {
		return .Not_Setup
	}
	b.enabled = false
	b.failed_attempts = 0
	b.locked_until = 0
	b.updated_at = time.to_unix_seconds(time.now())
	t.state.bindings[user] = b
	if !totp_state_save(t) {
		return .Storage_Failure
	}
	return .None
}

// totp_regenerate_backup_codes replaces the recovery set, invalidating every
// old code, and returns the new ones to show once.
totp_regenerate_backup_codes :: proc(
	t: ^Totp,
	user: string,
	allocator := context.allocator,
) -> ([]string, Totp_Error) {
	if t == nil || !t.initialized {
		return nil, .Not_Setup
	}
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)

	b, ok := t.state.bindings[user]
	if !ok || !b.enabled {
		return nil, .Not_Enabled
	}
	codes := totp_generate_backup_codes(t.backup_count, allocator)
	hashes := make([]Totp_Backup_Code, len(codes), t.alloc)
	for code, i in codes {
		hashes[i] = Totp_Backup_Code{code_hash = totp_hash_backup_code(t, user, code, t.alloc)}
	}
	totp_backups_store(t, user, hashes)
	if !totp_state_save(t) {
		totp_free_backup_codes(codes, allocator)
		return nil, .Storage_Failure
	}
	return codes, .None
}

// ---------------------------------------------------------------------------
// verification
// ---------------------------------------------------------------------------

// totp_enrolled reports whether the user has an *active* binding, i.e.
// whether a login for them needs a code at all.
totp_enrolled :: proc(t: ^Totp, user: string) -> bool {
	if t == nil || !t.initialized {
		return false
	}
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)
	b, ok := t.state.bindings[user]
	return ok && b.enabled
}

/*
totp_verify checks a 6-digit code for an active binding.

The windows within `skew` on both sides are all evaluated (no early exit) so
the response time does not say which window matched. A code that was
accepted before is refused even while it is still inside the skew window
(`.Code_Already_Used`): the same digits arriving twice is either a replay or
a shared secret.

A wrong code spends one attempt; `max_attempts` wrong ones lock the binding
for `lock_secs`. The counter resets when the lock expires, so a locked-out
user gets a full budget again rather than being locked on the first typo.
*/
totp_verify :: proc(t: ^Totp, user, code: string) -> Totp_Error {
	if t == nil || !t.initialized {
		return .Not_Setup
	}
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)

	b, ok := t.state.bindings[user]
	if !ok || !b.enabled {
		return .Not_Enabled
	}
	now := time.to_unix_seconds(time.now())
	if totp_lockout_active(t, &b, now) {
		return .Account_Locked
	}

	secret, secret_ok := totp_decrypt_secret(b.secret_enc, t.master_key, t.alloc)
	if !secret_ok {
		return .Crypto_Failure
	}
	defer delete(secret, t.alloc)

	matched, window := totp_match_code(secret, code, t, time.now())
	if !matched {
		totp_record_failure(t, user, b, now)
		return .Invalid_Code
	}
	if totp_code_was_used(t, user, code, now) {
		return .Code_Already_Used
	}
	totp_remember_code(t, user, window, code, now)
	b.failed_attempts = 0
	b.locked_until = 0
	b.updated_at = now
	t.state.bindings[user] = b
	if !totp_state_save(t) {
		return .Storage_Failure
	}
	return .None
}

// totp_verify_backup spends one recovery code. The hash is keyed with the
// user id, so a code from one account's list never validates for another
// even if both files leak.
totp_verify_backup :: proc(t: ^Totp, user, code: string) -> Totp_Error {
	if t == nil || !t.initialized {
		return .Not_Setup
	}
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)

	b, ok := t.state.bindings[user]
	if !ok || !b.enabled {
		return .Not_Enabled
	}
	now := time.to_unix_seconds(time.now())
	if totp_lockout_active(t, &b, now) {
		return .Account_Locked
	}

	want := totp_hash_backup_code(t, user, code, t.alloc)
	defer delete(want, t.alloc)

	list := t.state.backups[user]
	found := -1
	for entry, i in list {
		if common.secure_eq(entry.code_hash, want) {
			found = i
			break
		}
	}
	if found < 0 {
		totp_record_failure(t, user, b, now)
		return .Invalid_Backup_Code
	}
	if list[found].used {
		return .Invalid_Backup_Code
	}
	// The map value is a slice header; writing through it updates the one
	// entry in place, so no reallocation (and no string copy) is involved.
	list[found].used = true

	b.failed_attempts = 0
	b.locked_until = 0
	b.updated_at = now
	t.state.bindings[user] = b
	if !totp_state_save(t) {
		return .Storage_Failure
	}
	return .None
}

// totp_status answers the settings page: on/off, whether a binding exists at
// all, whether it is locked, and how many recovery codes are left.
totp_status :: proc(t: ^Totp, user: string) -> Totp_Status {
	if t == nil || !t.initialized {
		return {}
	}
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)

	b, ok := t.state.bindings[user]
	status := Totp_Status{has_binding = ok, enabled = ok && b.enabled}
	if ok {
		status.locked = b.locked_until > time.to_unix_seconds(time.now())
	}
	for entry in t.state.backups[user] {
		if !entry.used {
			status.backup_codes += 1
		}
	}
	return status
}

// ---------------------------------------------------------------------------
// lockout and replay bookkeeping (callers hold t.mu)
// ---------------------------------------------------------------------------

// totp_lockout_active reports whether the binding is locked, and clears an
// expired lock (with its counter) as a side effect.
@(private = "file")
totp_lockout_active :: proc(t: ^Totp, b: ^Totp_Binding, now: i64) -> bool {
	if b.locked_until == 0 {
		return false
	}
	if now < b.locked_until {
		return true
	}
	b.locked_until = 0
	b.failed_attempts = 0
	return false
}

@(private = "file")
totp_record_failure :: proc(t: ^Totp, user: string, binding: Totp_Binding, now: i64) {
	b := binding // parameters are immutable; the map gets the copy back
	if t.max_attempts == 0 {
		// locking disabled: still persist the counter as a diagnostic
		b.failed_attempts += 1
	} else if b.failed_attempts + 1 >= t.max_attempts {
		b.failed_attempts = 0
		b.locked_until = now + i64(t.lock_secs)
	} else {
		b.failed_attempts += 1
	}
	b.updated_at = now
	t.state.bindings[user] = b
	totp_state_save(t)
}

// totp_code_was_used answers "did this exact code succeed recently". The
// horizon covers every window the code could still be accepted in.
@(private = "file")
totp_code_was_used :: proc(t: ^Totp, user, code: string, now: i64) -> bool {
	for entry in t.state.used[user] {
		if now - entry.used_at <= i64(t.period * (2 * t.skew + 3)) && entry.code == code {
			return true
		}
	}
	return false
}

// totp_remember_code appends the accepted code and drops entries that have
// aged out, so the list stays proportional to logins in the last minutes.
@(private = "file")
totp_remember_code :: proc(t: ^Totp, user: string, window: i64, code: string, now: i64) {
	horizon := i64(t.period * (2 * t.skew + 3))
	old := t.state.used[user]

	kept := 0
	for entry in old {
		if now - entry.used_at <= horizon {
			kept += 1
		}
	}
	next := make([]Totp_Used_Code, kept + 1, t.alloc)
	n := 0
	for entry in old {
		if now - entry.used_at <= horizon {
			next[n] = entry // the string stays; only the array is rebuilt
			n += 1
		} else {
			delete(entry.code, t.alloc)
		}
	}
	next[n] = Totp_Used_Code {window = window, code = buffer.clone_string(code, t.alloc), used_at = now}

	delete(old, t.alloc)
	// the key is only stored, never freed by the caller: clone it once, the
	// same way the binding and backup maps do
	key := user
	if _, exists := t.state.used[user]; !exists {
		key = buffer.clone_string(user, t.alloc)
	}
	t.state.used[key] = next
	totp_state_save(t)
}

// ---------------------------------------------------------------------------
// state storage
// ---------------------------------------------------------------------------

@(private = "file")
totp_state_make :: proc(alloc: mem.Allocator) -> Totp_State {
	return Totp_State {
		bindings = make(map[string]Totp_Binding, alloc),
		backups  = make(map[string][]Totp_Backup_Code, alloc),
		used     = make(map[string][]Totp_Used_Code, alloc),
	}
}

// totp_state_destroy frees every string the state owns before the maps that
// reference them: `delete(map)` releases the buckets, not the keys.
@(private = "file")
totp_state_destroy :: proc(state: ^Totp_State, alloc: mem.Allocator) {
	for user, &b in state.bindings {
		delete(b.secret_enc, alloc)
		delete(user, alloc)
	}
	delete(state.bindings)

	for user, &list in state.backups {
		for entry in list {
			delete(entry.code_hash, alloc)
		}
		delete(list, alloc)
		delete(user, alloc)
	}
	delete(state.backups)

	for user, &list in state.used {
		for entry in list {
			delete(entry.code, alloc)
		}
		delete(list, alloc)
		delete(user, alloc)
	}
	delete(state.used)
	state^ = {}
}

// totp_binding_store writes a binding, cloning the key only when it is new
// (an overwrite keeps the map's existing key, so cloning would leak).
@(private = "file")
totp_binding_store :: proc(t: ^Totp, user: string, b: Totp_Binding) {
	if old, exists := t.state.bindings[user]; exists {
		if old.secret_enc != b.secret_enc {
			delete(old.secret_enc, t.alloc)
		}
		t.state.bindings[user] = b
		return
	}
	t.state.bindings[buffer.clone_string(user, t.alloc)] = b
}

@(private = "file")
totp_backups_store :: proc(t: ^Totp, user: string, list: []Totp_Backup_Code) {
	old := t.state.backups[user]
	for entry in old {
		delete(entry.code_hash, t.alloc)
	}
	delete(old, t.alloc)
	if _, exists := t.state.backups[user]; !exists {
		t.state.backups[buffer.clone_string(user, t.alloc)] = list
	} else {
		t.state.backups[user] = list
	}
}

// totp_state_load / totp_state_save own the file. The backup list is only
// replaced wholesale, so no per-entry copy helper is needed here.

@(private = "file")
totp_state_load :: proc(t: ^Totp) {
	if len(t.path) == 0 {
		return
	}
	data, err := os.read_entire_file(t.path, t.alloc)
	if err != nil {
		// A missing file is the normal first run. A broken one is not
		// silently overwritten: an empty state would quietly disable 2FA
		// for everyone, so the caller sees it through
		// `totp_load_failed` before anything is written.
		if err != os.General_Error.Not_Exist {
			t.load_failed = true
		}
		return
	}
	defer delete(data, t.alloc)

	loaded := Totp_State{}
	if json.unmarshal(data, &loaded, allocator = t.alloc) != nil {
		t.load_failed = true
		return
	}
	if loaded.bindings == nil {
		loaded.bindings = make(map[string]Totp_Binding, t.alloc)
	}
	if loaded.backups == nil {
		loaded.backups = make(map[string][]Totp_Backup_Code, t.alloc)
	}
	if loaded.used == nil {
		loaded.used = make(map[string][]Totp_Used_Code, t.alloc)
	}

	totp_state_destroy(&t.state, t.alloc)
	t.state = loaded
}

/*
totp_state_save writes the state file. It goes through a temporary file and
a rename so a crash mid-write leaves the previous file intact - a truncated
JSON would lose every enrollment at the next start, which is exactly the
moment 2FA is supposed to still work.

A failure here is reported to the caller as `.Storage_Failure`. It is not
rolled back: the in-memory state is the truth for this process, and the next
successful save persists it.
*/
@(private = "file")
totp_state_save :: proc(t: ^Totp) -> bool {
	if len(t.path) == 0 {
		return true
	}
	if t.load_failed {
		// Refuse to write over a file we could not read: an empty state
		// would silently turn 2FA off for every account. The caller sees
		// `.Storage_Failure` and has to fix the file first.
		return false
	}
	data, err := json.marshal(t.state, allocator = t.alloc)
	if err != nil {
		return false
	}
	defer delete(data, t.alloc)

	if dir := totp_parent_dir(t.path); len(dir) > 0 {
		os.mkdir_all(dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	}
	tmp := buffer.concat_strings({t.path, ".tmp"}, t.alloc)
	defer delete(tmp, t.alloc)

	perm := os.Permissions{.Read_User, .Write_User}
	if os.write_entire_file_from_bytes(tmp, data, perm) != nil {
		return false
	}
	return os.rename(tmp, t.path) == nil
}

// totp_parent_dir extracts "./dir/file.db" -> "./dir" without allocating a
// second string. Empty when the path has no directory component.
@(private = "file")
totp_parent_dir :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[:i]
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// TOTP core (RFC 4226 / RFC 6238)
// ---------------------------------------------------------------------------

TOTP_BASE32_ALPHABET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

// totp_base32_encode encodes without padding. Authenticator apps accept a
// padded secret too, but the URI is shorter and the QR denser without it.
totp_base32_encode :: proc(data: []byte, allocator := context.allocator) -> string {
	alphabet := TOTP_BASE32_ALPHABET
	out := make([dynamic]byte, 0, (len(data) * 8 + 4) / 5, allocator)
	acc: u32
	bits: u32
	for b in data {
		acc = (acc << 8) | u32(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			append(&out, alphabet[(acc >> bits) & 0x1f])
		}
		acc &= (1 << bits) - 1
	}
	if bits > 0 {
		append(&out, alphabet[(acc << (5 - bits)) & 0x1f])
	}
	return string(out[:])
}

// totp_base32_decode accepts lower case, spaces, '-' and '=' because a user
// typing a secret by hand will produce all of them, and rejects anything
// else (including a dangling partial character).
totp_base32_decode :: proc(s: string, allocator := context.allocator) -> ([]byte, bool) {
	out := make([dynamic]byte, 0, (len(s) * 5) / 8 + 1, allocator)
	acc: u32
	bits: u32
	chars := 0
	for i in 0..<len(s) {
		c := s[i]
		if c == '=' || c == ' ' || c == '-' || c == '\t' {
			continue
		}
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		value, ok := totp_base32_value(c)
		if !ok {
			delete(out)
			return nil, false
		}
		chars += 1
		acc = (acc << 5) | u32(value)
		bits += 5
		if bits >= 8 {
			bits -= 8
			append(&out, byte((acc >> bits) & 0xff))
		}
		acc &= (1 << bits) - 1
	}
	if chars == 0 || acc != 0 {
		delete(out)
		return nil, false
	}
	return out[:], true
}

@(private = "file")
totp_base32_value :: proc(c: byte) -> (int, bool) {
	switch {
	case c >= 'A' && c <= 'Z':
		return int(c - 'A'), true
	case c >= '2' && c <= '7':
		return int(c - '2') + 26, true
	}
	return 0, false
}

// totp_hotp computes one HOTP value into `dst` (RFC 4226 section 5.3: HMAC,
// dynamic truncation, mod 10^digits). Writing into the caller's stack buffer
// keeps verification allocation-free.
totp_hotp :: proc(dst: []byte, secret: []byte, counter: i64, digits: int) -> (code: []byte, ok: bool) {
	if digits <= 0 || digits > 8 || len(dst) < digits {
		return nil, false
	}
	msg: [8]byte
	u := u64(counter)
	for i in 0..<8 {
		msg[7 - i] = byte((u >> (8 * u64(i))) & 0xff)
	}
	digest: [20]byte
	hmac.sum(hash.Algorithm.Insecure_SHA1, digest[:], msg[:], secret)

	offset := int(digest[19] & 0x0f)
	bin := u32(digest[offset] & 0x7f) << 24 |
		u32(digest[offset + 1]) << 16 |
		u32(digest[offset + 2]) << 8 |
		u32(digest[offset + 3])
	mod := u32(1)
	for _ in 0..<digits {
		mod *= 10
	}
	value := bin % mod
	for i := digits - 1; i >= 0; i -= 1 {
		dst[i] = byte('0' + value % 10)
		value /= 10
	}
	return dst[:digits], true
}

// totp_match_code checks `code` against every window in `[-skew, +skew]` and
// returns the matched window. All windows are evaluated so the loop cost -
// and therefore the response time - does not reveal which one hit.
@(private = "file")
totp_match_code :: proc(secret_b32, code: string, t: ^Totp, now: time.Time) -> (matched: bool, window: i64) {
	if len(code) != t.digits {
		return false, 0
	}
	for i in 0..<len(code) {
		if code[i] < '0' || code[i] > '9' {
			return false, 0
		}
	}
	secret, ok := totp_base32_decode(secret_b32, t.alloc)
	if !ok {
		return false, 0
	}
	defer delete(secret, t.alloc)

	secs := time.to_unix_seconds(now)
	current := secs / i64(t.period)
	buf: [8]byte
	for step in -t.skew..=t.skew {
		candidate := current + i64(step)
		generated, hotp_ok := totp_hotp(buf[:], secret, candidate, t.digits)
		if !hotp_ok {
			continue
		}
		if common.secure_eq(string(generated), code) && !matched {
			matched = true
			window = candidate
		}
	}
	return matched, window
}

// totp_otpauth_uri builds the standard key URI (the QR payload).
totp_otpauth_uri :: proc(secret, user, issuer: string, allocator := context.allocator) -> string {
	// label and issuer are percent-encoded so a user id with ':' or '@'
	// does not split the path segment.
	encoded_user := http.url_encode(user, allocator)
	encoded_issuer := http.url_encode(issuer, allocator)
	defer {
		delete(encoded_user, allocator)
		delete(encoded_issuer, allocator)
	}
	return buffer.concat_strings({
		"otpauth://totp/",
		encoded_issuer,
		":",
		encoded_user,
		"?secret=",
		secret,
		"&issuer=",
		encoded_issuer,
	}, allocator)
}

// ---------------------------------------------------------------------------
// secrets: AEAD at rest, backup codes
// ---------------------------------------------------------------------------

// totp_encrypt_secret seals the base32 secret as
// base64(iv || tag || ciphertext) with ChaCha20-Poly1305.
totp_encrypt_secret :: proc(plain: string, key: [32]byte, allocator: mem.Allocator) -> (string, bool) {
	k := key // a parameter is not addressable, so `k[:]` needs a local
	iv: [12]byte
	crypto.rand_bytes(iv[:])
	tag: [16]byte
	aad := TOTP_ENCRYPTION_AAD
	ciphertext := make([]byte, len(plain), allocator)
	aead.seal_oneshot(
		.CHACHA20POLY1305,
		ciphertext,
		tag[:],
		k[:],
		iv[:],
		transmute([]byte) aad,
		transmute([]byte) plain,
	)
	blob := make([]byte, 12 + 16 + len(ciphertext), allocator)
	copy(blob[0:12], iv[:])
	copy(blob[12:28], tag[:])
	copy(blob[28:], ciphertext)
	delete(ciphertext, allocator)

	encoded, err := base64.encode(blob, allocator = allocator)
	delete(blob, allocator)
	if err != nil {
		return "", false
	}
	return encoded, true
}

// totp_decrypt_secret opens a blob written by totp_encrypt_secret. The tag
// is checked before anything is returned: a tampered file yields "", false.
totp_decrypt_secret :: proc(encoded: string, key: [32]byte, allocator: mem.Allocator) -> (string, bool) {
	blob, err := base64.decode(encoded, allocator = allocator)
	if err != nil {
		return "", false
	}
	defer delete(blob, allocator)
	if len(blob) < 12 + 16 {
		return "", false
	}
	iv := blob[0:12]
	tag := blob[12:28]
	ciphertext := blob[28:]

	k := key
	aad := TOTP_ENCRYPTION_AAD
	plain := make([]byte, len(ciphertext), allocator)
	if !aead.open_oneshot(
		.CHACHA20POLY1305,
		plain,
		k[:],
		iv,
		transmute([]byte) aad,
		ciphertext,
		tag,
	) {
		delete(plain, allocator)
		return "", false
	}
	return string(plain), true
}

// totp_generate_backup_codes makes `count` codes of the form "A1B2-C3D4":
// eight hex digits from four random bytes, which is 32 bits per code - far
// beyond guessing, and short enough to type once.
totp_generate_backup_codes :: proc(count: int, allocator := context.allocator) -> []string {
	if count <= 0 {
		return nil
	}
	digits := TOTP_HEX_UPPER
	out := make([]string, count, allocator)
	for i in 0..<count {
		raw: [4]byte
		crypto.rand_bytes(raw[:])
		// "A1B2-C3D4": eight upper-case hex digits, dash in the middle so
		// the code is readable when it is read off a screen.
		buf: [9]byte
		pos := 0
		for b, j in raw {
			if j == 2 {
				buf[pos] = '-'
				pos += 1
			}
			buf[pos] = digits[b >> 4]
			pos += 1
			buf[pos] = digits[b & 0x0f]
			pos += 1
		}
		out[i] = buffer.clone_string(string(buf[:]), allocator)
	}
	return out
}

TOTP_HEX_UPPER :: "0123456789ABCDEF"

@(private = "file")
totp_free_backup_codes :: proc(codes: []string, allocator: mem.Allocator) {
	for code in codes {
		delete(code, allocator)
	}
	delete(codes, allocator)
}

// totp_hash_backup_code keys the code hash with the master key *and* the
// user id: the digest of a code is meaningless for any other account.
totp_hash_backup_code :: proc(t: ^Totp, user, code: string, allocator: mem.Allocator) -> string {
	normalized: [64]byte
	n := 0
	for i in 0..<len(code) {
		if n >= len(normalized) {
			break // absurdly long input: the hash of a truncation still
			      // cannot match a code the app generated
		}
		c := code[i]
		if c == '-' || c == ' ' || c == '\t' {
			continue
		}
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		normalized[n] = c
		n += 1
	}

	separator: [1]byte
	msg := buffer.concat_strings({user, string(separator[:]), string(normalized[:n])}, allocator)
	defer delete(msg, allocator)
	key := t.master_key
	tag: [32]byte
	hmac.sum(hash.Algorithm.SHA256, tag[:], transmute([]byte) msg, key[:])

	hexed: [64]byte
	totp_hex_encode_into(hexed[:], tag[:])
	return buffer.clone_string(string(hexed[:]), allocator)
}

// ---------------------------------------------------------------------------
// hex / misc helpers
// ---------------------------------------------------------------------------

// totp_hex_decode_key parses the 64-character master key into 32 bytes
// without allocating.
@(private = "file")
totp_hex_decode_key :: proc(s: string) -> ([32]byte, bool) {
	key: [32]byte
	if len(s) != TOTP_MASTER_KEY_BYTES * 2 {
		return key, false
	}
	for i in 0..<TOTP_MASTER_KEY_BYTES {
		hi, hi_ok := totp_hex_value(s[i * 2])
		lo, lo_ok := totp_hex_value(s[i * 2 + 1])
		if !hi_ok || !lo_ok {
			return key, false
		}
		key[i] = hi << 4 | lo
	}
	return key, true
}

@(private = "file")
totp_hex_value :: proc(c: byte) -> (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

@(private = "file")
totp_hex_encode_into :: proc(dst: []byte, src: []byte) {
	digits := "0123456789abcdef"
	for b, i in src {
		dst[i * 2] = digits[b >> 4]
		dst[i * 2 + 1] = digits[b & 0x0f]
	}
}

@(private = "file")
totp_default_positive :: proc(value, fallback: int) -> int {
	if value > 0 {
		return value
	}
	return fallback
}
