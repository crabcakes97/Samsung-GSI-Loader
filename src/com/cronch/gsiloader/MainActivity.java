package com.cronch.gsiloader;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaRecorder;
import android.os.BatteryManager;
import android.os.HandlerThread;
import android.util.Size;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.method.LinkMovementMethod;
import android.text.method.ScrollingMovementMethod;
import android.text.style.ClickableSpan;
import android.os.Looper;
import android.view.View;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.ScrollView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.security.MessageDigest;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {

    // GSI source selection. The two LineageOS entries are presets that keep the
    // original behaviour; CUSTOM accepts any GSI as a URL or a local file path.
    // The Lineage presets are the ONLY sources that ever enable the
    // version-coupled framework patches by default (see patch toggles below).
    public enum GsiSource {
        LINEAGE_VANILLA,
        LINEAGE_GAPPS,
        LINEAGE_EROFS_VANILLA,
        LINEAGE_EROFS_GAPPS,
        CUSTOM
    }

    private TextView tvRootStatus;
    private TextView tvOsStatus;
    private TextView tvImageStatus;
    private TextView tvHeaderSubtitle;
    private TextView tvDownloadDesc;
    private TextView tvDownloadProgress;
    private ProgressBar pbDownload;
    private TextView tvConsoleLog;
    private TextView tvLogStatus;

    private LinearLayout cardFlavorVanilla;
    private LinearLayout cardFlavorGapps;
    private LinearLayout cardFlavorErofsVanilla;
    private LinearLayout cardFlavorErofsGapps;
    private LinearLayout cardCustom;
    private RadioButton rbVanilla;
    private RadioButton rbGapps;
    private RadioButton rbErofsVanilla;
    private RadioButton rbErofsGapps;
    private RadioButton rbCustom;
    private RadioGroup rgFilesystem;
    private RadioButton rbFsExt4;
    private RadioButton rbFsErofs;
    private EditText etCustomLocation;
    private Button btnBrowseGsi;
    private Button btnInspectGsi;
    // 5.9.10: filesystem picker state ("ext4" or "erofs"). Preset
    // sources imply it (EROFS sources -> erofs, 23.2 sources -> ext4);
    // CUSTOM leaves it alone. Guard stops programmatic radio sets
    // from re-firing the picker listener.
    private String selectedFilesystem = "ext4";
    private boolean updatingFilesystemUi = false;
    private static final int REQ_PICK_GSI = 1001;
    private RadioGroup rgTheme;
    private static final String PREF_THEME = "theme";
    private static boolean assetsLogShown = false;
    private String currentTheme = "dark";
    private CheckBox cbPatchFramework;
    private CheckBox cbPatchPermission;
    private CheckBox cbPatchApexList;

    private Button btnInstallGsi;
    private Button btnGuestShell;
    private TextView tvLastInstall;
    private volatile boolean downloading = false;
    private volatile boolean imageInstalled = false;
    private Button btnVerifyGsi;
    private Spinner spSlot;
    private List<String> slotValues = new ArrayList<>();
    private TextView tvRootProvider;
    private TextView tvSuBinary;
    private LinearLayout sectionUnrooted;
    private Button btnRecheckRoot;
    private Button btnOpenRmgn;
    private TextView tvInfoSlot;
    private TextView tvInfoOs;
    private TextView tvInfoSize;
    private TextView tvInfoFormat;
    private TextView tvInfoNote;
    private TextView tvInfoBoots;
    private TextView tvInfoSha;
    // 5.9.5-INT-START
    private View vSlotColor;
    private Button btnSlotColor;
    private TextView tvInfoStorage;
    private Button btnShareLog;
    private static final String PREF_COLOR_PREFIX = "slot_color_";
    // 5.9.5-INT-END
    private Button btnEditNote;
    // Guard so a slow SHA-256 is not queued twice for the same file.
    // Touched only from the single-thread executor and the main thread
    // posting back; worst case of a race is one wasted recompute.
    private String checksumComputingKey = null;
    private TextView tvFooterCredits;
    private Button btnCreateSlot;
    private Button btnDeleteSlot;
    private Button btnDuplicateSlot;
    private Button btnWipeSlot;
    // 5.9.11: clean-slate button (slots section) + wipe-after-install
    // toggle (hero section, next to Install).
    private Button btnCleanSlate;
    private CheckBox cbWipeAfterInstall;
    private boolean wipeAfterInstall = false;
    private boolean slotSpinnerInit = false;
    private Button btnBackupGsi;
    private Button btnRestoreGsi;
    private Button btnDeleteLineage;
    private Button btnBootGsi;
    private Button btnReturnOneUI;
    private Button btnBackupLauncher;
    private Button btnRestoreLauncher;
    // 5.9.5-APP-START
    private TextView tvBatteryStatus;
    private CheckBox cbBatteryGuard;
    private TextView tvSlotBootInfo;
    private CheckBox cbAutoboot;
    private Button btnReturnReboot;
    private TextView tvSnapshotList;
    private Button btnSnapshotRefresh;
    private Button btnSnapshotCreate;
    private Button btnSnapshotRollback;
    private Button btnBackupMulti;
    private Button btnVerifyBackup;
    private CheckBox cbGuestRoot;
    private TextView tvGuestRootState;
    private TextView tvFrameworkVersion;
    private Spinner spDensity;
    private EditText etDensityCustom;
    private CheckBox cbShareFolder;
    private TextView tvGuestFixesStatus;
    private Button btnPreflight;
    private TextView tvPreflightResult;
    private Button btnPauseDownload;
    private Button btnResumeDownload;
    private CheckBox cbLogAutoscroll;
    private Button btnViewLogcat;
    private boolean logAutoScroll = true;
    // 5.9.14: live log stream state + Experimental button.
    private volatile Process liveLogProcess = null;
    private volatile Thread liveLogThread = null;
    private volatile String liveLogTag = null;
    private Button btnExperimental;
    private boolean batteryGuardEnabled = true;
    private int batteryPct = -1;
    private boolean batteryCharging = false;
    // 5.9.7: session-persistent battery override + picker-copy gate.
    private boolean batteryOverrideSession = false;
    private volatile boolean pickerCopying = false;
    private long lastInstallTapMs = 0;
    // 5.9.17: one install at a time (see installGsi / installLocalGsi /
    // startNetworkDownload). Atomic so a task-start check and a UI
    // check cannot both claim the slot.
    private final java.util.concurrent.atomic.AtomicBoolean installBusy = new java.util.concurrent.atomic.AtomicBoolean(false);
    // 5.9.17: ownership transfer for the corrupt-download retry: the
    // failing task queues its retry without clearing installBusy, and
    // the retry task consumes this flag instead of fighting the CAS.
    private volatile boolean installHandoff = false;
    // 5.9.17: progress-poller generation (see streamInstallProgress).
    // Bumped at task start, at poller start, and at completion, so a
    // late poller post can never overwrite the final UI.
    private final java.util.concurrent.atomic.AtomicInteger installProgressGen = new java.util.concurrent.atomic.AtomicInteger(0);
    // 5.9.17: true once the user has parked the log above its tail by
    // hand (see the touch listener in onCreate). Auto-follow pauses
    // while pinned and resumes the moment they scroll back to the
    // tail (or re-check the auto-scroll box).
    private volatile boolean logUserPinned = false;
    private long lastBootTapMs = 0;
    // 5.9.16: slot whose return is currently being streamed, so
    // streamReturnProgress can record its last-boot outcome on
    // RETURN_OK. Set on the main thread at Return tap time (the
    // selected slot at tap time is the returning slot); read only
    // from the poller. The Return light path (no guest running)
    // never sets it — a no-op Return is not a session end and must
    // not overwrite the last real outcome.
    private volatile String returningSlot = null;
    private static final String PREF_UI_STYLE = "ui_style";
    private String uiStyle = "stage";
    private boolean moreToolsExpanded = false;
    private ProgressBar pbOperation;
    private TextView tvOperationProgress;
    // 5.9.11: one colorful progress bar + label per major function
    // (user-requested; each bar lives next to its own button, tinted
    // with the theme's vivid accent in the layout). Install keeps
    // pbOperation; Download keeps pbDownload.
    private ProgressBar pbBoot; private TextView tvBootProgress;
    private ProgressBar pbReturn; private TextView tvReturnProgress;
    private ProgressBar pbReboot; private TextView tvRebootProgress;
    private ProgressBar pbInspect; private TextView tvInspectProgress;
    private ProgressBar pbVerify; private TextView tvVerifyProgress;
    private ProgressBar pbBackup; private TextView tvBackupProgress;
    private ProgressBar pbSlot; private TextView tvSlotProgress;
    private ProgressBar pbWipe; private TextView tvWipeProgress;
    private ProgressBar pbCleanSlate; private TextView tvCleanSlateProgress;
    private ProgressBar pbSnapshot; private TextView tvSnapshotProgress;
    private ProgressBar pbGuestShell; private TextView tvGuestShellProgress;
    private ProgressBar pbPreflight; private TextView tvPreflightProgress;
    private ProgressBar pbLauncher; private TextView tvLauncherProgress;
    private ProgressBar pbLog; private TextView tvLogProgress;
    private RadioGroup rgUiStyle;
    private Button btnHowToUse;
    private Button btnMoreTools;
    private LinearLayout rootContainer;
    private LinearLayout sectionHeader;
    private LinearLayout sectionDevwarn;
    private LinearLayout sectionStatus;
    private LinearLayout sectionHero;
    private LinearLayout sectionPatches;
    private LinearLayout sectionSlots;
    private LinearLayout sectionSnapshots;
    private LinearLayout sectionGuest;
    private LinearLayout sectionSafety;
    private LinearLayout sectionLog;
    private LinearLayout sectionLook;
    private boolean autobootPrompted = false;
    private boolean updatingGuestRootUi = false;
    private boolean densitySpinnerInit = false;
    private volatile boolean downloadPauseRequested = false;
    // 5.9.9: one automatic fresh re-download per user-initiated install
    // when the script reports DOWNLOAD_CORRUPT (a resumed download that
    // reassembled a corrupt archive). Reset on every new user install /
    // resume tap; the auto-retry call itself must NOT reset it, or the
    // retry could loop forever.
    private boolean corruptDownloadRetried = false;
    private String lastDownloadUrl = null;
    private long lastDownloadExpected = -1;
    private String lastDownloadLabel = null;
    private String detectedFrameworkVersion = "unknown";
    private String detectedFrameworkLabel = "unknown";
    private static final String PREF_BATTERY_GUARD = "battery_guard";
    private static final String PREF_LOG_AUTOSCROLL = "log_autoscroll";
    private static final String PREF_AUTOBOOT = "autoboot_enabled";
    private static final String PREF_AUTOBOOT_SLOT = "autoboot_slot";
    private static final String PREF_DENSITY_PREFIX = "slot_density_";
    private static final String PREF_SHARE_PREFIX = "slot_share_";
    private static final String PREF_GUEST_ROOT_PREFIX = "slot_guest_root_";
    private static final String PREF_LAST_INSTALL = "last_install_text";
    private static final String PREF_ASSETS_VERSION = "assets_bundle_version";
    private static final String PREF_FIRST_RUN_WARNED = "first_run_warned";
    private static final int REQ_PROBE_PERMS = 1002;
    // 5.9.5-APP-END

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    // 5.9.16: picker copies run here, NOT on the main executor. The main
    // executor serializes root ops, so a long download/install/boot-progress
    // task queued ahead of a picker copy used to starve the copy: the copy
    // never landed, pickerCopying stayed true, and Install stayed disabled
    // (but looked enabled — btn_skin_primary has no disabled state) for
    // the whole wait, i.e. "Install does nothing" after picking a file.
    // A dedicated single thread keeps copies serialized among themselves
    // while independent of root-op queueing.
    private final ExecutorService pickerExecutor = Executors.newSingleThreadExecutor();
    // 5.9.16: log-streaming/polling runs HERE, not on the executor
    // above. The old design queued streamBootProgress /
    // streamReturnProgress on the same single thread as every root
    // mutation, with a comment claiming "no deadlock because
    // sequential" — an ordering assumption, not a guarantee: a hung
    // stream (a takeover log that never reaches TAKEOVER LAUNCHED,
    // a return log that never reaches RETURN_OK) occupied the one
    // thread for its whole 120–180 s cap, and any install/boot/wipe
    // queued behind it waited silently; worse, a stream that never
    // returned at all wedged every later root op. The sequential
    // ordering was never actually needed: pollers only READ
    // append-only log files (tail -n +K) and report through
    // appendLog / showFuncBarPct, both of which post to
    // mainHandler, so they never mutate slot state and never race a
    // root mutation — they are safe to run concurrently, and a hung
    // poller now only costs its own thread. Root mutations stay
    // serialized on the executor above; pollers stay off it.
    private final ExecutorService pollExecutor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    // 5.9.11: engine readiness (see extractAssets). Volatile so the
    // Install/Boot gates on the main thread see the background
    // task's result. Single-thread executor is DELIBERATE: it
    // serializes root mutations (install vs wipe vs slot ops) so two
    // taps can never race on the same slot — instant feedback comes
    // from main-thread log lines, not from parallel execution.
    private volatile boolean assetsReady = false;
    private volatile boolean assetsExtracting = false;
    private boolean isRootGranted = false;
    private String suBinary = "su";
    private GsiSource selectedSource = GsiSource.LINEAGE_GAPPS;
    private String customLocation = "";

    // Compatibility patches. These were built against LineageOS 23.2's
    // framework and are VERSION-COUPLED: binding them over a different GSI's
    // framework can break boot. They must never be applied silently to an
    // arbitrary GSI, so they default to OFF and are only auto-enabled when
    // the user picks a LineageOS preset. The user can always override them.
    private boolean patchFramework = false;
    private boolean patchPermissionController = false;
    private boolean patchApexList = false;

    // NOTE: the directory name is historical (kept so existing installs keep
    // working); it holds ANY GSI's system.raw, not just LineageOS.
    private static final String STAGE_DIR = "/data/local/tmp/lineage_stage";
    private static final String SYSTEM_RAW = STAGE_DIR + "/system.raw";
    // Flags file the app writes into its files dir; boot sync copies it to
    // STAGE_DIR, where master_prepare.sh sources it before binding patches.
    private static final String GSI_FLAGS_FILE = "gsi_flags.conf";

    // LineageOS presets (kept for backwards compatibility with the original
    // app; they are no longer the only supported sources).
    private static final String PRESET_URL_VANILLA = "https://downloads.sourceforge.net/project/misterztr-gsi/LineageOS/Android%2016/LineageOS-23.2-20260524-VANILLA-EXT4-GSI.7z?use_mirror=autoselect";
    private static final String PRESET_URL_GAPPS = "https://downloads.sourceforge.net/project/misterztr-gsi/LineageOS/Android%2016/LineageOS-23.2-20260524-GAPPS-EXT4-GSI.7z?use_mirror=autoselect";
    private static final long ESTIMATED_VANILLA_BYTES = 922022276L;
    private static final long ESTIMATED_GAPPS_BYTES = 1167859370L;
    // 5.9.11: EROFS presets. CORRECTION to 5.9.10's claim: 23.2 EROFS
    // builds DO exist — LineageOS-23.2-20260524-VANILLA-EROFS and
    // -GAPPS-EROFS are both published in the Android 16 folder, and
    // both URLs were HEAD-verified on SourceForge (200 OK) on
    // 2026-10-28. All four presets are now the 23.2-20260524 release,
    // so the 23.2 compatibility patches apply to EROFS too (the
    // filesystem differs, the framework does not). Sizes below are
    // the HEAD-measured Content-Lengths, not estimates — they feed
    // only the download progress estimate.
    private static final String PRESET_URL_EROFS_VANILLA = "https://downloads.sourceforge.net/project/misterztr-gsi/LineageOS/Android%2016/LineageOS-23.2-20260524-VANILLA-EROFS-GSI.7z?use_mirror=autoselect";
    private static final String PRESET_URL_EROFS_GAPPS = "https://downloads.sourceforge.net/project/misterztr-gsi/LineageOS/Android%2016/LineageOS-23.2-20260524-GAPPS-EROFS-GSI.7z?use_mirror=autoselect";
    private static final long ESTIMATED_EROFS_VANILLA_BYTES = 1038664917L;
    private static final long ESTIMATED_EROFS_GAPPS_BYTES = 1329618017L;

    private static final String PREFS_NAME = "gsi_prefs";
    private static final String PREF_SOURCE = "gsi_source";
    private static final String PREF_FILESYSTEM = "filesystem";
    private static final String PREF_CUSTOM_LOCATION = "custom_location";
    private static final String PREF_PATCH_FRAMEWORK = "patch_framework";
    private static final String PREF_PATCH_PERMISSION = "patch_permission";
    private static final String PREF_PATCH_APEX_LIST = "patch_apex_list";
    private static final String PREF_SLOT = "selected_slot";
    // 5.9.11: wipe-guest-userdata-after-install toggle (persisted,
    // default off so it never surprises anyone).
    private static final String PREF_WIPE_AFTER_INSTALL = "wipe_after_install";
    // 5.9.4 perks: per-slot notes, boot counts, checksums — all in the
    // same app prefs, keyed by slot name (slot names are already
    // restricted to [A-Za-z0-9_-]{1,32}, so they are safe key parts).
    private static final String PREF_NOTE_PREFIX = "slot_note_";
    private static final String PREF_BOOTS_PREFIX = "slot_boots_";
    private static final String PREF_SHA_PREFIX = "slot_sha_";
    private static final String PREF_LAST_BOOT = "last_booted_slot";
    // 5.9.16: per-slot last-boot outcome, recorded from the three
    // signals the app already has — UI Activator log (home reached),
    // watchdog marker (watchdog timeout), pstore verdict (reboot /
    // panic) — plus Return completion. Value: "<code>|<epochMs>",
    // codes: home, timeout, returned, reboot, panic. Shown in the
    // slot picker (refreshSlots labels) and the slot card
    // (refreshSlotInfo). This REPLACES displaying PREF_LAST_BOOT
    // (which stores a slot NAME, not a time) as if it were a date.
    private static final String PREF_LAST_BOOT_OUTCOME_PREFIX = "slot_last_boot_outcome_";

    // Slots (5.9.3, userspace recovery): the "Default" slot IS the original
    // single install (STAGE_DIR/system.raw, unchanged behaviour). Named
    // slots live under STAGE_DIR/slots/<name>/ with their own system.raw,
    // rootfs, and guest data dir. Slot names are sanitized to
    // [A-Za-z0-9_-]{1,32} in Java AND re-validated by every script.
    private static final String DEFAULT_SLOT = "Default";
    private String selectedSlot = DEFAULT_SLOT;

    private static boolean isValidSlotName(String n) {
        return n != null && n.length() >= 1 && n.length() <= 32 && n.matches("[A-Za-z0-9_-]+");
    }
    private String slotDir(String slot) {
        if (slot == null || slot.equals(DEFAULT_SLOT)) return STAGE_DIR;
        return STAGE_DIR + "/slots/" + slot;
    }
    private String currentSlotDir() { return slotDir(selectedSlot); }
    private String currentSystemRaw() { return currentSlotDir() + "/system.raw"; }
    private String currentRootfs() { return currentSlotDir() + "/rootfs"; }
    private boolean isDefaultSlot() { return selectedSlot == null || selectedSlot.equals(DEFAULT_SLOT); }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        applyTheme();
        setContentView(R.layout.activity_main);

        tvRootStatus = findViewById(R.id.tv_root_status);
        tvOsStatus = findViewById(R.id.tv_os_status);
        tvImageStatus = findViewById(R.id.tv_image_status);
        tvHeaderSubtitle = findViewById(R.id.tv_header_subtitle);
        tvDownloadDesc = findViewById(R.id.tv_download_desc);
        tvDownloadProgress = findViewById(R.id.tv_download_progress);
        pbDownload = findViewById(R.id.pb_download);
        tvConsoleLog = findViewById(R.id.tv_console_log);
        // 5.9.14: the log view never had a scroll handler, so finger
        // scrolling did nothing — only the auto-scroll moved it. Give
        // it one, so the log can be read back by hand.
        if (tvConsoleLog != null) tvConsoleLog.setMovementMethod(new ScrollingMovementMethod());
        // 5.9.17: the log box sits inside the page ScrollView, which
        // otherwise steals vertical drags — the box could never be
        // scrolled by hand. Let drags starting on the log stay with
        // the log, and remember when the user parks it above the tail
        // (pinned: auto-follow pauses) versus back at the tail
        // (pinned clears: following resumes). Returns false so the
        // movement method still handles the drag itself.
        if (tvConsoleLog != null) tvConsoleLog.setOnTouchListener((v, ev) -> {
            int a = ev.getAction();
            if (a == android.view.MotionEvent.ACTION_DOWN) {
                if (v.getParent() != null) v.getParent().requestDisallowInterceptTouchEvent(true);
            } else if (a == android.view.MotionEvent.ACTION_UP || a == android.view.MotionEvent.ACTION_CANCEL) {
                try {
                    boolean atBottom = true;
                    if (tvConsoleLog.getLayout() != null) {
                        int contentH = tvConsoleLog.getLayout().getLineTop(tvConsoleLog.getLineCount());
                        int visibleH = tvConsoleLog.getHeight() - tvConsoleLog.getPaddingTop() - tvConsoleLog.getPaddingBottom();
                        atBottom = tvConsoleLog.getScrollY() + visibleH >= contentH - 8;
                    }
                    logUserPinned = !atBottom;
                } catch (Exception ignored) {}
            }
            return false;
        });
        tvLogStatus = findViewById(R.id.tv_log_status);

        cardFlavorVanilla = findViewById(R.id.card_flavor_vanilla);
        cardFlavorGapps = findViewById(R.id.card_flavor_gapps);
        cardFlavorErofsVanilla = findViewById(R.id.card_flavor_erofs_vanilla);
        cardFlavorErofsGapps = findViewById(R.id.card_flavor_erofs_gapps);
        cardCustom = findViewById(R.id.card_custom);
        rbVanilla = findViewById(R.id.rb_vanilla);
        rbGapps = findViewById(R.id.rb_gapps);
        rbErofsVanilla = findViewById(R.id.rb_erofs_vanilla);
        rbErofsGapps = findViewById(R.id.rb_erofs_gapps);
        rbCustom = findViewById(R.id.rb_custom);
        rgFilesystem = findViewById(R.id.rg_filesystem);
        rbFsExt4 = findViewById(R.id.rb_fs_ext4);
        rbFsErofs = findViewById(R.id.rb_fs_erofs);
        etCustomLocation = findViewById(R.id.et_custom_location);
        btnBrowseGsi = findViewById(R.id.btn_browse_gsi);
        btnInspectGsi = findViewById(R.id.btn_inspect_gsi);
        cbPatchFramework = findViewById(R.id.cb_patch_framework);
        cbPatchPermission = findViewById(R.id.cb_patch_permission);
        cbPatchApexList = findViewById(R.id.cb_patch_apex_list);

        btnInstallGsi = findViewById(R.id.btn_install_gsi);
        btnGuestShell = findViewById(R.id.btn_guest_shell);
        tvLastInstall = findViewById(R.id.tv_last_install);
        btnVerifyGsi = findViewById(R.id.btn_verify_gsi);
        btnBackupGsi = findViewById(R.id.btn_backup_gsi);
        btnRestoreGsi = findViewById(R.id.btn_restore_gsi);
        btnDeleteLineage = findViewById(R.id.btn_delete_lineage);
        btnBootGsi = findViewById(R.id.btn_boot_gsi);
        btnReturnOneUI = findViewById(R.id.btn_return_oneui);
        btnBackupLauncher = findViewById(R.id.btn_backup_launcher);
        btnRestoreLauncher = findViewById(R.id.btn_restore_launcher);
        tvRootProvider = findViewById(R.id.tv_root_provider);
        tvSuBinary = findViewById(R.id.tv_su_binary);
        sectionUnrooted = findViewById(R.id.section_unrooted);
        btnRecheckRoot = findViewById(R.id.btn_recheck_root);
        btnOpenRmgn = findViewById(R.id.btn_open_rmgn);
        tvInfoSlot = findViewById(R.id.tv_info_slot);
        tvInfoOs = findViewById(R.id.tv_info_os);
        tvInfoSize = findViewById(R.id.tv_info_size);
        tvInfoFormat = findViewById(R.id.tv_info_format);
        tvInfoNote = findViewById(R.id.tv_info_note);
        tvInfoBoots = findViewById(R.id.tv_info_boots);
        tvInfoSha = findViewById(R.id.tv_info_sha);
        btnEditNote = findViewById(R.id.btn_edit_note);
        tvFooterCredits = findViewById(R.id.tv_footer_credits);
        spSlot = findViewById(R.id.sp_slot);
        btnCreateSlot = findViewById(R.id.btn_create_slot);
        btnDeleteSlot = findViewById(R.id.btn_delete_slot);
        btnDuplicateSlot = findViewById(R.id.btn_duplicate_slot);
        btnWipeSlot = findViewById(R.id.btn_wipe_slot);
        btnCleanSlate = findViewById(R.id.btn_clean_slate);
        cbWipeAfterInstall = findViewById(R.id.cb_wipe_after_install);
        // 5.9.7 bindings (new views only; every 5.9.6 binding above untouched).
        pbOperation = findViewById(R.id.pb_operation);
        tvOperationProgress = findViewById(R.id.tv_operation_progress);
        // 5.9.11: per-function bars (each null-safe: the helpers check).
        pbBoot = findViewById(R.id.pb_boot);
        tvBootProgress = findViewById(R.id.tv_boot_progress);
        pbReturn = findViewById(R.id.pb_return);
        tvReturnProgress = findViewById(R.id.tv_return_progress);
        pbReboot = findViewById(R.id.pb_reboot);
        tvRebootProgress = findViewById(R.id.tv_reboot_progress);
        pbInspect = findViewById(R.id.pb_inspect);
        tvInspectProgress = findViewById(R.id.tv_inspect_progress);
        pbVerify = findViewById(R.id.pb_verify);
        tvVerifyProgress = findViewById(R.id.tv_verify_progress);
        pbBackup = findViewById(R.id.pb_backup);
        tvBackupProgress = findViewById(R.id.tv_backup_progress);
        pbSlot = findViewById(R.id.pb_slot);
        tvSlotProgress = findViewById(R.id.tv_slot_progress);
        pbWipe = findViewById(R.id.pb_wipe);
        tvWipeProgress = findViewById(R.id.tv_wipe_progress);
        pbCleanSlate = findViewById(R.id.pb_clean_slate);
        tvCleanSlateProgress = findViewById(R.id.tv_clean_slate_progress);
        pbSnapshot = findViewById(R.id.pb_snapshot);
        tvSnapshotProgress = findViewById(R.id.tv_snapshot_progress);
        pbGuestShell = findViewById(R.id.pb_guest_shell);
        tvGuestShellProgress = findViewById(R.id.tv_guest_shell_progress);
        pbPreflight = findViewById(R.id.pb_preflight);
        tvPreflightProgress = findViewById(R.id.tv_preflight_progress);
        pbLauncher = findViewById(R.id.pb_launcher);
        tvLauncherProgress = findViewById(R.id.tv_launcher_progress);
        pbLog = findViewById(R.id.pb_log);
        tvLogProgress = findViewById(R.id.tv_log_progress);
        rgUiStyle = findViewById(R.id.rg_ui_style);
        btnHowToUse = findViewById(R.id.btn_how_to_use);
        btnMoreTools = findViewById(R.id.btn_more_tools);
        rootContainer = findViewById(R.id.root_container);
        sectionHeader = findViewById(R.id.section_header);
        sectionDevwarn = findViewById(R.id.section_devwarn);
        sectionStatus = findViewById(R.id.section_status);
        sectionHero = findViewById(R.id.section_hero);
        sectionPatches = findViewById(R.id.section_patches);
        sectionSlots = findViewById(R.id.section_slots);
        sectionSnapshots = findViewById(R.id.section_snapshots);
        sectionGuest = findViewById(R.id.section_guest);
        sectionSafety = findViewById(R.id.section_safety);
        sectionLog = findViewById(R.id.section_log);
        sectionLook = findViewById(R.id.section_look);
        if (btnHowToUse != null) btnHowToUse.setOnClickListener(v -> showGuideDialog());
        if (btnMoreTools != null) btnMoreTools.setOnClickListener(v -> toggleMoreTools());

        restoreGsiPrefs();
        setupFooterLinks();
        setupSourceSelection();
        setupThemeSelection();
        setupUiStyleSelection();
        // 5.9.6: restore the last-install line, the resume state for any
        // interrupted download left by a previous run, and drop stale
        // file-picker copies (transient cache, never user data).
        restoreLastInstallText();
        restoreResumeState();
        cleanupStalePickerCache();
        maybeShowFirstRunWarning();
        // 5.9.5-APP-START
        setup595Views();
        applyUiStyle();
        animateEntrance();
        wirePressFeedback();
        refreshBattery();
        // 5.9.5-APP-END
        extractAssets();
        checkRootAndSystem();
        refreshSlots();
        // 5.9.16: launch-time slot reconcile (see reconcileSlots)
        // — single authority for slot-record vs on-disk drift.
        reconcileSlots();

        btnInstallGsi.setOnClickListener(v -> installGsi());
        if (btnGuestShell != null) btnGuestShell.setOnClickListener(v -> promptGuestShell());
        btnDeleteLineage.setOnClickListener(v -> confirmDeleteGsi());
        if (btnVerifyGsi != null) btnVerifyGsi.setOnClickListener(v -> verifyGsi());
        if (btnBackupGsi != null) btnBackupGsi.setOnClickListener(v -> backupGsi());
        if (btnRestoreGsi != null) btnRestoreGsi.setOnClickListener(v -> confirmRestoreGsi());
        btnBootGsi.setOnClickListener(v -> bootGsi());
        btnReturnOneUI.setOnClickListener(v -> returnToOneUI());
        btnBackupLauncher.setOnClickListener(v -> backupLauncher());
        btnRestoreLauncher.setOnClickListener(v -> restoreLauncher());
        if (btnBrowseGsi != null) btnBrowseGsi.setOnClickListener(v -> launchGsiPicker());
        if (spSlot != null) spSlot.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            public void onItemSelected(AdapterView<?> parent, View view, int pos, long id) {
                if (!slotSpinnerInit) return;
                if (pos < 0 || pos >= slotValues.size()) return;
                String sel = slotValues.get(pos);
                if (sel != null && !sel.equals(selectedSlot)) {
                    selectedSlot = sel;
                    saveGsiPrefs();
                    appendLog("Slot selected: " + sel + (isDefaultSlot() ? " (original single install)" : " (slots/" + sel + ")"));
                    checkImageStatus();
                    // 5.9.5-APP-START
                    refresh595SlotControls();
                    refreshGuestRootState();
                    // 5.9.5-APP-END
                }
            }
            public void onNothingSelected(AdapterView<?> parent) {}
        });
        if (btnCreateSlot != null) btnCreateSlot.setOnClickListener(v -> createSlot());
        if (btnDeleteSlot != null) btnDeleteSlot.setOnClickListener(v -> deleteSlot());
        if (btnDuplicateSlot != null) btnDuplicateSlot.setOnClickListener(v -> duplicateSlot());
        if (btnWipeSlot != null) btnWipeSlot.setOnClickListener(v -> confirmWipeSlot());
        if (btnCleanSlate != null) btnCleanSlate.setOnClickListener(v -> confirmCleanSlate());
        if (btnEditNote != null) btnEditNote.setOnClickListener(v -> promptNoteEdit());
        if (btnRecheckRoot != null) btnRecheckRoot.setOnClickListener(v -> {
            checkRootAndSystem();
            refreshRootInfo();
            refreshSlots();
        });
        if (btnOpenRmgn != null) btnOpenRmgn.setOnClickListener(v -> {
            try {
                Intent i = new Intent(Intent.ACTION_VIEW,
                        Uri.parse("https://github.com/rushiranpise/Root-My-Galaxy-Next"));
                startActivity(i);
            } catch (Exception e) {
                appendLog("Could not open browser for Root-My-Galaxy-Next: " + e.getMessage());
            }
        });
    }

    @Override
    protected void onResume() {
        super.onResume();
        // 5.9.5-APP-START
        refreshBattery();
        // 5.9.5-APP-END
        checkRootAndSystem();
        refreshSlots();
        refreshRootInfo();
        // 5.9.11: surface a watchdog-triggered return from the last
        // boot, once (no-op when no watchdog marker exists).
        surfaceWatchdogOutcome();
        // 5.9.13: self-heal stale guest-running markers left by a
        // force-restart (no-op when none are stale). Runs on the
        // executor; never blocks the UI thread.
        sweepStaleGuestMarkers();
    }

    // Theme must be applied before setContentView so every ?attr/ color
    // resolves against the chosen theme at inflation time.
    private void applyTheme() {
        try {
            currentTheme = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_THEME, "dark");
        } catch (Exception ignored) { currentTheme = "dark"; }
        switch (currentTheme) {
            case "light": setTheme(R.style.Theme_GsiLoader_Light); break;
            case "black": setTheme(R.style.Theme_GsiLoader_Black); break;
            case "materialyou": setTheme(R.style.Theme_GsiLoader_MaterialYou); break;
            // 5.9.5-APP-START
            case "original": setTheme(R.style.Theme_GsiLoader_Original); break;
            case "emerald": setTheme(R.style.Theme_GsiLoader_Emerald); break;
            case "sunset": setTheme(R.style.Theme_GsiLoader_Sunset); break;
            case "violet": setTheme(R.style.Theme_GsiLoader_Violet); break;
            case "neon": setTheme(R.style.Theme_GsiLoader_Neon); break;
            case "arctic": setTheme(R.style.Theme_GsiLoader_Arctic); break;
            case "rose": setTheme(R.style.Theme_GsiLoader_Rose); break;
            // 5.9.5-APP-END
            default: setTheme(R.style.Theme_GsiLoader_Dark); break;
        }
    }

    private void setupThemeSelection() {
        rgTheme = findViewById(R.id.rg_theme);
        if (rgTheme == null) return;
        int checkId = R.id.rb_theme_dark;
        if ("light".equals(currentTheme)) checkId = R.id.rb_theme_light;
        else if ("black".equals(currentTheme)) checkId = R.id.rb_theme_black;
        else if ("materialyou".equals(currentTheme)) checkId = R.id.rb_theme_materialyou;
        // 5.9.5-APP-START
        else if ("original".equals(currentTheme)) checkId = R.id.rb_theme_original;
        else if ("emerald".equals(currentTheme)) checkId = R.id.rb_theme_emerald;
        else if ("sunset".equals(currentTheme)) checkId = R.id.rb_theme_sunset;
        else if ("violet".equals(currentTheme)) checkId = R.id.rb_theme_violet;
        else if ("neon".equals(currentTheme)) checkId = R.id.rb_theme_neon;
        else if ("arctic".equals(currentTheme)) checkId = R.id.rb_theme_arctic;
        else if ("rose".equals(currentTheme)) checkId = R.id.rb_theme_rose;
        // 5.9.5-APP-END
        rgTheme.check(checkId);
        rgTheme.setOnCheckedChangeListener((group, checkedId) -> {
            String next = "dark";
            if (checkedId == R.id.rb_theme_light) next = "light";
            else if (checkedId == R.id.rb_theme_black) next = "black";
            else if (checkedId == R.id.rb_theme_materialyou) next = "materialyou";
            // 5.9.5-APP-START
            else if (checkedId == R.id.rb_theme_original) next = "original";
            else if (checkedId == R.id.rb_theme_emerald) next = "emerald";
            else if (checkedId == R.id.rb_theme_sunset) next = "sunset";
            else if (checkedId == R.id.rb_theme_violet) next = "violet";
            else if (checkedId == R.id.rb_theme_neon) next = "neon";
            else if (checkedId == R.id.rb_theme_arctic) next = "arctic";
            else if (checkedId == R.id.rb_theme_rose) next = "rose";
            // 5.9.5-APP-END
            if (!next.equals(currentTheme)) {
                currentTheme = next;
                try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putString(PREF_THEME, next).apply(); } catch (Exception ignored) {}
                recreate();
            }
        });
    }

    private void setupSourceSelection() {
        cardFlavorVanilla.setOnClickListener(v -> selectSource(GsiSource.LINEAGE_VANILLA, true));
        cardFlavorGapps.setOnClickListener(v -> selectSource(GsiSource.LINEAGE_GAPPS, true));
        if (cardFlavorErofsVanilla != null) cardFlavorErofsVanilla.setOnClickListener(v -> selectSource(GsiSource.LINEAGE_EROFS_VANILLA, true));
        if (cardFlavorErofsGapps != null) cardFlavorErofsGapps.setOnClickListener(v -> selectSource(GsiSource.LINEAGE_EROFS_GAPPS, true));
        cardCustom.setOnClickListener(v -> selectSource(GsiSource.CUSTOM, true));
        // 5.9.10: filesystem picker. Switching keeps the same flavor
        // when a preset is picked; for Custom it only switches which
        // preset cards are shown for the next pick.
        if (rgFilesystem != null) rgFilesystem.setOnCheckedChangeListener((group, checkedId) -> {
            if (updatingFilesystemUi) return;
            if (checkedId == R.id.rb_fs_erofs) onFilesystemPicked("erofs");
            else if (checkedId == R.id.rb_fs_ext4) onFilesystemPicked("ext4");
        });
        if (btnInspectGsi != null) btnInspectGsi.setOnClickListener(v -> inspectGsi());

        cbPatchFramework.setOnCheckedChangeListener((v, checked) -> {
            patchFramework = checked;
            saveGsiPrefs();
            writeGsiFlagsFile();
        });
        cbPatchPermission.setOnCheckedChangeListener((v, checked) -> {
            patchPermissionController = checked;
            saveGsiPrefs();
            writeGsiFlagsFile();
        });
        cbPatchApexList.setOnCheckedChangeListener((v, checked) -> {
            patchApexList = checked;
            saveGsiPrefs();
            writeGsiFlagsFile();
        });

        // Apply the restored source without clobbering restored toggles.
        selectSource(selectedSource, false);
        applyPatchTogglesToUi();
        if (etCustomLocation != null) etCustomLocation.setText(customLocation);
    }

    // applyDefaults=true is only used for explicit user taps: picking a
    // Lineage preset turns the Lineage-built patches on (original behaviour),
    // picking Custom turns them off (safe default for an arbitrary GSI).
    // The user can then override any toggle by hand.
    private void selectSource(GsiSource source, boolean applyDefaults) {
        selectedSource = source;
        rbVanilla.setChecked(source == GsiSource.LINEAGE_VANILLA);
        rbGapps.setChecked(source == GsiSource.LINEAGE_GAPPS);
        if (rbErofsVanilla != null) rbErofsVanilla.setChecked(source == GsiSource.LINEAGE_EROFS_VANILLA);
        if (rbErofsGapps != null) rbErofsGapps.setChecked(source == GsiSource.LINEAGE_EROFS_GAPPS);
        rbCustom.setChecked(source == GsiSource.CUSTOM);

        cardFlavorVanilla.setBackgroundResource(source == GsiSource.LINEAGE_VANILLA ? R.drawable.radio_skin_selected : R.drawable.radio_skin_unselected);
        cardFlavorGapps.setBackgroundResource(source == GsiSource.LINEAGE_GAPPS ? R.drawable.radio_skin_selected : R.drawable.radio_skin_unselected);
        if (cardFlavorErofsVanilla != null) cardFlavorErofsVanilla.setBackgroundResource(source == GsiSource.LINEAGE_EROFS_VANILLA ? R.drawable.radio_skin_selected : R.drawable.radio_skin_unselected);
        if (cardFlavorErofsGapps != null) cardFlavorErofsGapps.setBackgroundResource(source == GsiSource.LINEAGE_EROFS_GAPPS ? R.drawable.radio_skin_selected : R.drawable.radio_skin_unselected);
        cardCustom.setBackgroundResource(source == GsiSource.CUSTOM ? R.drawable.radio_skin_selected : R.drawable.radio_skin_unselected);

        // Only the Custom source shows the URL/path field and the file
        // picker (5.9.6: the Android 17 preset entries are gone entirely).
        boolean showCustomField = source == GsiSource.CUSTOM;
        etCustomLocation.setVisibility(showCustomField ? View.VISIBLE : View.GONE);
        if (btnBrowseGsi != null) btnBrowseGsi.setVisibility(showCustomField ? View.VISIBLE : View.GONE);

        switch (source) {
            case LINEAGE_VANILLA:
                tvDownloadDesc.setText("Preset: LineageOS 23.2, no Google apps (lightweight). Tap Install to download it, then install it.");
                if (applyDefaults) setPatchToggles(true, true, true);
                break;
            case LINEAGE_GAPPS:
                tvDownloadDesc.setText("Preset: LineageOS 23.2 with Google Play Store and Play Services. Tap Install to download it, then install it.");
                if (applyDefaults) setPatchToggles(true, true, true);
                break;
            case LINEAGE_EROFS_VANILLA:
                tvDownloadDesc.setText("Preset: LineageOS 23.2, no Google apps, EROFS filesystem (read-only, faster reads). Tap Install to download it, then install it.");
                if (applyDefaults) setPatchToggles(true, true, true);
                break;
            case LINEAGE_EROFS_GAPPS:
                tvDownloadDesc.setText("Preset: LineageOS 23.2 with Google Play Store and Play Services, EROFS filesystem. Tap Install to download it, then install it.");
                if (applyDefaults) setPatchToggles(true, true, true);
                break;
            case CUSTOM:
                tvDownloadDesc.setText("Your own system: paste a download link, or tap Browse to pick a file already on this phone. A picked file installs directly when you tap Install — it is not a download. Compatibility patches default to OFF for your own images.");
                if (applyDefaults) setPatchToggles(false, false, false);
                break;
        }
        // 5.9.10: preset sources imply the filesystem picker state;
        // CUSTOM leaves the picker where it was.
        if (source == GsiSource.LINEAGE_EROFS_VANILLA || source == GsiSource.LINEAGE_EROFS_GAPPS) {
            selectedFilesystem = "erofs";
        } else if (source == GsiSource.LINEAGE_VANILLA || source == GsiSource.LINEAGE_GAPPS) {
            selectedFilesystem = "ext4";
        }
        applyFilesystemToUi();
        saveGsiPrefs();
        writeGsiFlagsFile();
    }

    // 5.9.10: filesystem picker state -> UI. Shows one preset group
    // and hides the other; the Custom card is always visible. The
    // guard keeps this programmatic radio set from re-firing the
    // picker listener (which would loop back into selectSource).
    private void applyFilesystemToUi() {
        boolean erofs = "erofs".equals(selectedFilesystem);
        updatingFilesystemUi = true;
        try {
            if (rgFilesystem != null) rgFilesystem.check(erofs ? R.id.rb_fs_erofs : R.id.rb_fs_ext4);
        } catch (Exception ignored) {}
        updatingFilesystemUi = false;
        if (cardFlavorVanilla != null) cardFlavorVanilla.setVisibility(erofs ? View.GONE : View.VISIBLE);
        if (cardFlavorGapps != null) cardFlavorGapps.setVisibility(erofs ? View.GONE : View.VISIBLE);
        if (cardFlavorErofsVanilla != null) cardFlavorErofsVanilla.setVisibility(erofs ? View.VISIBLE : View.GONE);
        if (cardFlavorErofsGapps != null) cardFlavorErofsGapps.setVisibility(erofs ? View.VISIBLE : View.GONE);
    }

    // 5.9.10: user tapped the filesystem picker. A picked preset keeps
    // its flavor and switches filesystem; Custom only switches which
    // preset cards are shown for the next pick.
    private void onFilesystemPicked(String fs) {
        if ("erofs".equals(fs)) {
            if (selectedSource == GsiSource.LINEAGE_VANILLA) selectSource(GsiSource.LINEAGE_EROFS_VANILLA, true);
            else if (selectedSource == GsiSource.LINEAGE_GAPPS) selectSource(GsiSource.LINEAGE_EROFS_GAPPS, true);
            else { selectedFilesystem = "erofs"; applyFilesystemToUi(); saveGsiPrefs(); }
        } else {
            if (selectedSource == GsiSource.LINEAGE_EROFS_VANILLA) selectSource(GsiSource.LINEAGE_VANILLA, true);
            else if (selectedSource == GsiSource.LINEAGE_EROFS_GAPPS) selectSource(GsiSource.LINEAGE_GAPPS, true);
            else { selectedFilesystem = "ext4"; applyFilesystemToUi(); saveGsiPrefs(); }
        }
    }

    private void setPatchToggles(boolean framework, boolean permission, boolean apexList) {
        patchFramework = framework;
        patchPermissionController = permission;
        patchApexList = apexList;
        applyPatchTogglesToUi();
    }

    private void applyPatchTogglesToUi() {
        if (cbPatchFramework != null) cbPatchFramework.setChecked(patchFramework);
        if (cbPatchPermission != null) cbPatchPermission.setChecked(patchPermissionController);
        if (cbPatchApexList != null) cbPatchApexList.setChecked(patchApexList);
    }

    private void restoreGsiPrefs() {
        try {
            SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
            String saved = prefs.getString(PREF_SOURCE, GsiSource.LINEAGE_GAPPS.name());
            // 5.9.10: restore the filesystem picker first. selectSource
            // overrides it for preset sources (a saved EROFS source
            // implies erofs); for CUSTOM the restored value stands.
            String savedFs = prefs.getString(PREF_FILESYSTEM, "ext4");
            selectedFilesystem = "erofs".equals(savedFs) ? "erofs" : "ext4";
            try {
                selectedSource = GsiSource.valueOf(saved);
            } catch (Exception ignored) {
                // 5.9.6: the removed Android 17 presets migrate to Custom
                // (keeps the user's pasted URL/file path, patches stay off)
                // instead of falling back to a Lineage preset.
                if ("A17_GMS".equals(saved) || "A17_NOGMS".equals(saved) || "RESTLESS_A17".equals(saved)) {
                    selectedSource = GsiSource.CUSTOM;
                } else {
                    selectedSource = GsiSource.LINEAGE_GAPPS;
                }
            }
            customLocation = prefs.getString(PREF_CUSTOM_LOCATION, "");
            patchFramework = prefs.getBoolean(PREF_PATCH_FRAMEWORK, false);
            patchPermissionController = prefs.getBoolean(PREF_PATCH_PERMISSION, false);
            patchApexList = prefs.getBoolean(PREF_PATCH_APEX_LIST, false);
            // 5.9.5-APP-START
            batteryGuardEnabled = prefs.getBoolean(PREF_BATTERY_GUARD, true);
            logAutoScroll = prefs.getBoolean(PREF_LOG_AUTOSCROLL, true);
            // 5.9.5-APP-END
            // 5.9.11: wipe-after-install toggle (default off).
            wipeAfterInstall = prefs.getBoolean(PREF_WIPE_AFTER_INSTALL, false);
            String savedSlot = prefs.getString(PREF_SLOT, DEFAULT_SLOT);
            selectedSlot = isValidSlotName(savedSlot) ? savedSlot : DEFAULT_SLOT;
            // First run after upgrade from the Lineage-only app: the old
            // default was "patches always on". Keep that behaviour for
            // all four 23.2 presets (5.9.11: EROFS is 23.2 now, not
            // 23.0 — the patches were built for 23.2's files, and
            // EROFS vs EXT4 is a filesystem difference, not a
            // framework difference). Custom stays off, as before.
            if (!prefs.contains(PREF_PATCH_FRAMEWORK)
                    && (selectedSource == GsiSource.LINEAGE_VANILLA
                        || selectedSource == GsiSource.LINEAGE_GAPPS
                        || selectedSource == GsiSource.LINEAGE_EROFS_VANILLA
                        || selectedSource == GsiSource.LINEAGE_EROFS_GAPPS)) {
                patchFramework = true;
                patchPermissionController = true;
                patchApexList = true;
            }
        } catch (Exception ignored) {}
    }

    private void saveGsiPrefs() {
        try {
            if (etCustomLocation != null) {
                customLocation = etCustomLocation.getText().toString().trim();
            }
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
                    .putString(PREF_SOURCE, selectedSource.name())
                    .putString(PREF_FILESYSTEM, selectedFilesystem)
                    .putString(PREF_CUSTOM_LOCATION, customLocation)
                    .putBoolean(PREF_PATCH_FRAMEWORK, patchFramework)
                    .putBoolean(PREF_PATCH_PERMISSION, patchPermissionController)
                    .putBoolean(PREF_PATCH_APEX_LIST, patchApexList)
                    .putBoolean(PREF_WIPE_AFTER_INSTALL, wipeAfterInstall)
                    .putString(PREF_SLOT, selectedSlot)
                    .apply();
        } catch (Exception ignored) {}
    }

    // Writes the flags file master_prepare.sh sources before binding any
    // patched file. Written into the app files dir (no root needed); the
    // boot sync and the asset sync copy it into STAGE_DIR.
    private void writeGsiFlagsFile() {
        executor.execute(this::writeGsiFlagsFileSync);
    }

    private void writeGsiFlagsFileSync() {
        try {
            // 5.9.5-APP-START: boot env vars, mirrored in bootGsi() command env.
            String content = "PATCH_FRAMEWORK=" + (patchFramework ? "1" : "0") + "\n"
                    + "PATCH_PERMISSION_CONTROLLER=" + (patchPermissionController ? "1" : "0") + "\n"
                    + "USE_LINEAGE_APEX_LIST=" + (patchApexList ? "1" : "0") + "\n"
                    + "DENSITY_DPI=" + densityForSlot(selectedSlot) + "\n"
                    + "SHARE_FOLDER=" + (shareForSlot(selectedSlot) ? "1" : "0") + "\n"
                    + "FRAMEWORK_VERSION=" + detectedFrameworkVersion + "\n"
                    + "GUEST_ROOT=" + (guestRootForSlot(selectedSlot) ? "1" : "0") + "\n";
            // 5.9.6: the IMS / dev-options / codec toggles are gone — no
            // script ever read those flags (IMS keepalive in
            // switch_to_gsi.sh is unconditional; dev-options has no
            // workaround in this build), so writing them only pretended
            // to configure something. They are not written anymore.
            // 5.9.5-APP-END
            try (OutputStream out = new FileOutputStream(new File(getFilesDir(), GSI_FLAGS_FILE))) {
                out.write(content.getBytes("UTF-8"));
            }
        } catch (Exception e) {
            appendLog("Warning: could not write " + GSI_FLAGS_FILE + ": " + e.getMessage());
        }
    }

    private void appendLog(final String text) {
        mainHandler.post(() -> {
            // 5.9.5-APP-START: persisted operation log + autoscroll toggle.
            try {
                File logFile = new File(getFilesDir(), "operation_log.txt");
                if (logFile.exists() && logFile.length() > 524288) {
                    try {
                        byte[] all = new byte[(int) logFile.length()];
                        try (java.io.FileInputStream fin = new java.io.FileInputStream(logFile)) {
                            int off = 0, n;
                            while (off < all.length && (n = fin.read(all, off, all.length - off)) != -1) off += n;
                        }
                        int keep = all.length / 2;
                        try (OutputStream o2 = new FileOutputStream(logFile, false)) { o2.write(all, all.length - keep, keep); }
                    } catch (Exception ignored) {}
                }
                try (OutputStream out = new FileOutputStream(logFile, true)) {
                    out.write((text + "\n").getBytes("UTF-8"));
                }
            } catch (Exception ignored) {}
            if (tvConsoleLog != null) {
                tvConsoleLog.append(text + "\n");
                // 5.9.11: trim the log VIEW (bug fix). The log FILE was
                // trimmed at 512KB, but the TextView grew WITHOUT
                // bound — after a long session (thousands of lines)
                // every append re-laid-out a huge view and the UI got
                // visibly slower. Keep the last ~500 lines on screen
                // (the file keeps the full history).
                try {
                    android.text.Editable ed = tvConsoleLog.getEditableText();
                    int lines = 0;
                    for (int i = 0; i < ed.length(); i++) if (ed.charAt(i) == '\n') lines++;
                    if (lines > 1000) {
                        int keep = lines - 500, cut = 0;
                        for (int n = 0; n < keep && cut < ed.length(); n++) {
                            int nl = android.text.TextUtils.indexOf(ed, '\n', cut);
                            if (nl < 0) break;
                            cut = nl + 1;
                        }
                        if (cut > 0) ed.delete(0, cut);
                    }
                } catch (Exception ignored) {}
                // 5.9.17: follow the tail whenever auto-scroll is on
                // and the user has NOT pinned the log by scrolling up
                // (see the touch listener in onCreate). The 5.9.14
                // gate computed "was at bottom" from the CURRENT
                // scroll position, but the scroll only advanced when
                // the gate was true — so the first time content grew
                // past viewport + 80px slack, the gate closed forever
                // and the log froze at its first screenful. That is
                // why taps looked dead: every new line, including
                // every tap's feedback, appended below the visible
                // area and the view never moved.
                if (logAutoScroll && !logUserPinned) {
                    scrollLogToBottom();
                }
            }
            // 5.9.5-APP-END
        });
    }

    // 5.9.17: scroll the log TextView to its last line. The layout can
    // lag one frame behind the append, so if it does not yet cover the
    // new text, retry briefly instead of scrolling to the old bottom.
    private void scrollLogToBottom() {
        if (tvConsoleLog == null) return;
        tvConsoleLog.post(new Runnable() {
            int attempts = 0;
            @Override public void run() {
                try {
                    if (tvConsoleLog == null || tvConsoleLog.getLayout() == null) return;
                    android.text.Editable ed = tvConsoleLog.getEditableText();
                    int edLines = 0;
                    for (int i = 0; i < ed.length(); i++) if (ed.charAt(i) == '\n') edLines++;
                    if (tvConsoleLog.getLayout().getLineCount() < edLines && attempts < 3) {
                        attempts++;
                        tvConsoleLog.postDelayed(this, 50);
                        return;
                    }
                    int scrollAmount = tvConsoleLog.getLayout().getLineTop(tvConsoleLog.getLineCount()) - tvConsoleLog.getHeight();
                    if (scrollAmount > 0) tvConsoleLog.scrollTo(0, scrollAmount);
                } catch (Exception ignored) {}
            }
        });
    }

    // Runs a root shell command with stdout+stderr merged and continuously drained.
    // Process.waitFor() deadlocks forever if the child fills its stdout/stderr pipe
    // (~64KB) without anyone reading it - e.g. "rm -rf" spewing a "Device or resource
    // busy" line per file when rootfs still has stale bind/loop mounts underneath it.
    private int runRootCmdDrained(String cmd) {
        try {
            ProcessBuilder pb = new ProcessBuilder(suBinary, "-c", cmd);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
            while (reader.readLine() != null) {
                // drain only; callers that need the output use their own reader.
            }
            return p.waitFor();
        } catch (Exception e) {
            return -1;
        }
    }

    // 5.9.6: like runRootCmdDrained, but keeps the output lines so a
    // failure can report the script's REAL reason (e.g. the
    // INSTALL_ERROR line from install_image.sh) instead of a bare exit
    // code. Used by both install paths. Returns the exit code, or -1.
    private int runRootCmdCaptured(String cmd, List<String> out) {
        try {
            ProcessBuilder pb = new ProcessBuilder(suBinary, "-c", cmd);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = reader.readLine()) != null) {
                if (out != null) out.add(line);
            }
            return p.waitFor();
        } catch (Exception e) {
            if (out != null) out.add("RUN_ERROR: " + e.getMessage());
            return -1;
        }
    }

    // 5.9.7: like runRootCmdCaptured, but each output line reaches the
    // log AS IT ARRIVES (via appendLog) instead of only when the process
    // exits — this is what makes the log live during install/boot. The
    // captured variant stays only where a caller needs the full output
    // before deciding (guest shell, failure-reason reporting).
    private int runRootCmdStreamed(String cmd, List<String> out, boolean streamToLog) {
        try {
            ProcessBuilder pb = new ProcessBuilder(suBinary, "-c", cmd);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = reader.readLine()) != null) {
                if (out != null) out.add(line);
                if (streamToLog) appendLog(line);
            }
            return p.waitFor();
        } catch (Exception e) {
            if (out != null) out.add("RUN_ERROR: " + e.getMessage());
            return -1;
        }
    }

    // 5.9.6: the install scripts a non-default slot needs. install_image.sh
    // runs "$SLOT/7zz" and converts sparse images with "$SLOT/simg2img",
    // so a named slot needs all three — 5.9.5 copied only the first two,
    // which is why sparse local images failed in named slots even though
    // the converter is bundled (the script also falls back to the Default
    // stage copy now, belt and suspenders).
    private String installSlotScriptsCmd(String slotDir) {
        return "cp -f " + STAGE_DIR + "/install_image.sh " + STAGE_DIR + "/7zz " + STAGE_DIR + "/simg2img " + slotDir + "/ "
                + "&& chmod 755 " + slotDir + "/install_image.sh " + slotDir + "/7zz " + slotDir + "/simg2img";
    }

    // 5.9.6: best-effort sparse pre-check for a local file the app itself
    // can read (app cache / app-readable paths). Unreadable paths are
    // skipped silently — the install script is the authority there.
    private void logSparsePrecheck(String localPath) {
        try {
            java.io.FileInputStream in = new java.io.FileInputStream(new File(localPath));
            byte[] magic = new byte[4];
            int n = in.read(magic);
            in.close();
            if (n == 4 && (magic[0] & 0xFF) == 0x3A && (magic[1] & 0xFF) == 0xFF
                    && (magic[2] & 0xFF) == 0x26 && (magic[3] & 0xFF) == 0xED) {
                appendLog("Sparse image detected — it will be converted automatically with the bundled simg2img during install.");
            }
        } catch (Exception ignored) {}
    }

    private void setLastInstall(String text) {
        try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putString(PREF_LAST_INSTALL, text).apply(); } catch (Exception ignored) {}
        mainHandler.post(() -> { if (tvLastInstall != null) tvLastInstall.setText(text); });
    }

    private void restoreLastInstallText() {
        try {
            String t = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_LAST_INSTALL, null);
            if (t != null && !t.isEmpty() && tvLastInstall != null) tvLastInstall.setText(t);
        } catch (Exception ignored) {}
    }

    // 5.9.6: first-run development warning (also shown permanently as a
    // card on the main screen). Shown exactly once.
    private void maybeShowFirstRunWarning() {
        try {
            boolean warned = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getBoolean(PREF_FIRST_RUN_WARNED, false);
            if (warned) return;
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putBoolean(PREF_FIRST_RUN_WARNED, true).apply();
        } catch (Exception ignored) { return; }
        new AlertDialog.Builder(this)
            .setTitle("In development — some features may not work yet")
            .setMessage("This app is still being built, so a feature may fail or behave unexpectedly. Nothing here flashes your phone or changes Samsung, but a guest system may fail to install or boot. If a boot fails, reboot the phone: it always comes back to Samsung.")
            .setPositiveButton("OK", null)
            .show();
    }

    // 5.9.6: drop stale file-picker copies on launch. These are transient
    // copies the picker made in the app cache (the installed system.raw is
    // a separate copy, so deleting them loses nothing).
    private void cleanupStalePickerCache() {
        try {
            File dir = new File(getCacheDir(), "gsi_pick");
            if (dir.exists()) {
                File[] kids = dir.listFiles();
                if (kids != null) for (File k : kids) { try { k.delete(); } catch (Exception ignored) {} }
            }
        } catch (Exception ignored) {}
    }

    // 5.9.6: is there a real interrupted download that Resume could
    // continue? True when this session started one (lastDownloadUrl) or
    // when a previous run left both a state file (URL) and a partial
    // download file behind.
    private boolean resumablePartialExists() {
        if (lastDownloadUrl != null) return true;
        try {
            File state = new File(getCacheDir(), "gsi_dl.state");
            if (!state.exists()) return false;
            BufferedReader sr = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(state)));
            String url = sr.readLine();
            sr.close();
            if (url == null || url.isEmpty()) return false;
            File[] kids = getCacheDir().listFiles();
            if (kids != null) for (File k : kids) {
                String n = k.getName();
                if (n.startsWith("gsi_dl") && !n.equals("gsi_dl.state") && k.length() > 0) return true;
            }
        } catch (Exception ignored) {}
        return false;
    }

    // 5.9.6: Pause is only meaningful mid-download; Resume is only shown
    // when a real interrupted download exists. Called on every download
    // state transition and on launch.
    private void updateDownloadButtons() {
        mainHandler.post(() -> {
            if (btnPauseDownload != null) btnPauseDownload.setEnabled(downloading);
            if (btnResumeDownload != null) {
                btnResumeDownload.setVisibility((!downloading && resumablePartialExists()) ? View.VISIBLE : View.GONE);
            }
        });
    }

    // 5.9.6: restore an interrupted download's resume state from disk, so
    // Resume works across app restarts (5.9.5 kept it only in memory, so
    // after a restart the button could not resume anything at all).
    private void restoreResumeState() {
        try {
            File state = new File(getCacheDir(), "gsi_dl.state");
            if (!state.exists()) { updateDownloadButtons(); return; }
            BufferedReader sr = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(state)));
            String url = sr.readLine();
            sr.close();
            if (url == null || url.isEmpty()) { updateDownloadButtons(); return; }
            File[] kids = getCacheDir().listFiles();
            boolean partial = false;
            if (kids != null) for (File k : kids) {
                String n = k.getName();
                if (n.startsWith("gsi_dl") && !n.equals("gsi_dl.state") && k.length() > 0) { partial = true; break; }
            }
            if (partial) {
                lastDownloadUrl = url;
                lastDownloadExpected = -1;
                lastDownloadLabel = "Previous download";
                appendLog("Interrupted download found (" + url + ") — tap Resume download to continue it.");
            }
        } catch (Exception ignored) {}
        updateDownloadButtons();
    }

    // 5.9.6: save a typed custom density before boot. Previously the
    // custom field was only saved when it lost focus, so typing a number
    // and tapping Boot straight away silently booted with the old value.
    private void flushDensityField() {
        try {
            if (spDensity != null && spDensity.getSelectedItemPosition() == 6 && etDensityCustom != null) {
                String val = etDensityCustom.getText().toString().trim();
                if (val.matches("[0-9]+")) saveSlotString(PREF_DENSITY_PREFIX, selectedSlot, val);
            }
        } catch (Exception ignored) {}
    }

    // 5.9.6: guest root shell — the feature 5.9.5 shipped as a script with
    // no button. Asks for one shell command, runs it inside the running
    // guest via guest_root_shell.sh (nsenter), and prints the output in
    // the log. Refuses plainly when the guest is not running.
    private void promptGuestShell() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to run a command inside the guest!");
            return;
        }
        final EditText input = new EditText(this);
        input.setHint("e.g. id");
        input.setText("id");
        new AlertDialog.Builder(this)
            .setTitle("Run a command inside the guest (slot '" + selectedSlot + "')")
            .setMessage("The command runs inside the running guest and its output appears in the log. Only works while this slot's guest is running.")
            .setView(input)
            .setPositiveButton("Run", (dialog, which) -> {
                String cmd = input.getText().toString().trim();
                if (cmd.isEmpty()) { appendLog("ERROR: No command entered."); return; }
                runGuestShell(cmd);
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void runGuestShell(final String cmd) {
        final String slot = selectedSlot;
        final String dir = currentSlotDir();
        // 5.9.11: own colorful bar.
        runBarTask(pbGuestShell, tvGuestShellProgress, "Running guest command…", () -> {
            // Single-quote the user command for the shell (escape embedded
            // quotes); never pass it through runScriptLines, which mangles
            // spaces and quotes out of commands.
            String safe = cmd.replace("'", "'\\''");
            List<String> out = new ArrayList<>();
            int ret = runRootCmdCaptured("sh " + STAGE_DIR + "/guest_root_shell.sh " + dir + " '" + safe + "'", out);
            boolean err = false;
            for (String line : out) {
                if (line.contains("GUEST_ROOT_SHELL_ERROR")) err = true;
            }
            if (err || ret != 0) {
                appendLog("Guest command failed for slot '" + slot + "' (is the guest running?):");
                int shown = 0;
                for (String line : out) {
                    if (shown >= 20) break;
                    appendLog("  " + line);
                    shown++;
                }
            } else {
                appendLog("Guest command output (slot '" + slot + "' :: " + cmd + "):");
                int shown = 0;
                for (String line : out) {
                    if (shown >= 200) { appendLog("  … (output truncated at 200 lines)"); break; }
                    appendLog("  " + line);
                    shown++;
                }
                if (shown == 0) appendLog("  (no output)");
            }
        });
    }

    private void setLogStatus(final String status) {
        mainHandler.post(() -> {
            if (tvLogStatus != null) {
                tvLogStatus.setText(status);
            }
        });
    }

    private void checkRootAndSystem() {
        executor.execute(() -> {
            // Attempt auto-activation of ksud if present
            try {
                File dfKsud = new File("/data/user_de/0/df.root/ksud");
                if (dfKsud.exists() && dfKsud.canExecute()) {
                    Runtime.getRuntime().exec(new String[]{dfKsud.getAbsolutePath(), "install"}).waitFor();
                }
            } catch (Exception ignored) {}

            String[] candidatePaths = {"/system/bin/su", "/data/adb/ksu/bin/su", "/system/xbin/su", "su"};
            boolean foundRoot = false;

            for (String path : candidatePaths) {
                try {
                    Process p = Runtime.getRuntime().exec(new String[]{path, "-c", "id"});
                    BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line = reader.readLine();
                    int exitCode = p.waitFor();

                    if (exitCode == 0 && line != null && line.contains("uid=0")) {
                        foundRoot = true;
                        suBinary = path;
                        break;
                    }
                } catch (Exception ignored) {}
            }

            isRootGranted = foundRoot;
            if (isRootGranted) {
                extractAssets();
            }
            mainHandler.post(() -> {
                if (isRootGranted) {
                    // 5.9.6: the provider line below names the variant
                    // honestly; this line must not claim KernelSU when
                    // root came from another tool (e.g. Magisk).
                    tvRootStatus.setText("✓ Root: active (uid=0)");
                    tvRootStatus.setTextColor(Color.parseColor("#A5D6A7"));
                } else {
                    tvRootStatus.setText("✗ Root: Access Denied (root required)");
                    tvRootStatus.setTextColor(Color.parseColor("#FFB4AB"));
                }
                if (sectionUnrooted != null) {
                    sectionUnrooted.setVisibility(isRootGranted ? View.GONE : View.VISIBLE);
                }
                // 5.9.5-APP-START
                if (isRootGranted) maybePromptAutoboot();
                // 5.9.5-APP-END
            });
            refreshRootInfo();

            // Check active userspace. Generic detection: a Lineage guest still
            // reports ro.lineage.version, but any other GSI does not, so fall
            // back to the guest rootfs itself — if it is mounted, read its
            // build.prop display id; if nothing is mounted, we are on One UI.
            try {
                String osLabel = null;
                Process pOs = Runtime.getRuntime().exec(new String[]{suBinary, "-c", "getprop ro.lineage.version"});
                BufferedReader osReader = new BufferedReader(new InputStreamReader(pOs.getInputStream()));
                String osVer = osReader.readLine();
                pOs.waitFor();
                if (osVer != null && !osVer.trim().isEmpty()) {
                    osLabel = "LineageOS " + osVer.trim();
                } else {
                    Process pGuest = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                            "M=$(mount | grep -F 'lineage_stage' | grep -F 'rootfs ' | head -n 1 | sed -e 's/^.* on //; s/ type .*//'); "
                            + "if [ -n \"$M\" ]; then grep -m1 '^ro.build.display.id=' \"$M/system/build.prop\" 2>/dev/null | cut -d= -f2-; fi"});
                    BufferedReader guestReader = new BufferedReader(new InputStreamReader(pGuest.getInputStream()));
                    String guestId = guestReader.readLine();
                    pGuest.waitFor();
                    if (guestId != null && !guestId.trim().isEmpty()) {
                        osLabel = "Guest GSI (" + guestId.trim() + ")";
                    }
                }

                final String label = osLabel;
                mainHandler.post(() -> {
                    if (label != null) {
                        tvOsStatus.setText("Current Userspace: " + label);
                        tvOsStatus.setTextColor(Color.parseColor("#78D9EC"));
                        if (tvHeaderSubtitle != null) {
                            tvHeaderSubtitle.setText("Dual Userspace Switcher • Guest GSI");
                        }
                    } else {
                        tvOsStatus.setText("Current Userspace: Samsung One UI (Stock)");
                        tvOsStatus.setTextColor(Color.parseColor("#FFD54F"));
                        if (tvHeaderSubtitle != null) {
                            tvHeaderSubtitle.setText("Dual Userspace Switcher • One UI");
                        }
                    }
                });
            } catch (Exception e) {
                mainHandler.post(() -> tvOsStatus.setText("Current Userspace: Samsung One UI"));
            }

            checkImageStatus();
        });
    }

    // Credits footer: the crabcakes97 credit becomes a real tappable link
    // to https://github.com/crabcakes97. The rest of the footer text
    // (WeWaffles / MisterZtr / CRONCH) is left exactly as it is.
    private void setupFooterLinks() {
        if (tvFooterCredits == null) return;
        try {
            String text = tvFooterCredits.getText().toString();
            int start = text.indexOf("crabcakes97");
            if (start < 0) return;
            SpannableString span = new SpannableString(text);
            span.setSpan(new ClickableSpan() {
                @Override
                public void onClick(View widget) {
                    try {
                        startActivity(new Intent(Intent.ACTION_VIEW,
                                Uri.parse("https://github.com/crabcakes97")));
                    } catch (Exception e) {
                        appendLog("Could not open browser for crabcakes97: " + e.getMessage());
                    }
                }
                @Override
                public void updateDrawState(android.text.TextPaint ds) {
                    super.updateDrawState(ds);
                    ds.setColor(Color.parseColor("#78D9EC"));
                    ds.setUnderlineText(true);
                }
            }, start, start + "crabcakes97".length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            tvFooterCredits.setText(span);
            tvFooterCredits.setMovementMethod(LinkMovementMethod.getInstance());
            tvFooterCredits.setHighlightColor(Color.TRANSPARENT);
        } catch (Exception ignored) {}
    }

    // Root provider detection (display only, never faked): KernelSU-Next is
    // reported only when its manager package is installed; a KSU state dir
    // without the manager is reported as KSU-family/unknown; anything else
    // is honestly "unknown". No root-method switching exists in this app.
    private void refreshRootInfo() {
        executor.execute(() -> {
            final String su = suBinary;
            if (!isRootGranted) {
                mainHandler.post(() -> {
                    if (tvRootProvider != null) tvRootProvider.setText("Root provider: No root");
                    if (tvSuBinary != null) tvSuBinary.setText("su binary: —");
                });
                return;
            }
            boolean hasKsunextMgr = false, hasKsuDir = false, hasKsud = false;
            try {
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "pm list packages 2>/dev/null | grep -E 'com.rifsxd.ksunext'; "
                    + "ls -d /data/adb/ksu 2>/dev/null; ls /data/adb/ksu/bin/ksud 2>/dev/null"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                while ((line = r.readLine()) != null) {
                    if (line.contains("com.rifsxd.ksunext")) hasKsunextMgr = true;
                    if (line.trim().equals("/data/adb/ksu")) hasKsuDir = true;
                    if (line.contains("ksud")) hasKsud = true;
                }
                p.waitFor();
            } catch (Exception ignored) {}
            final String provider;
            if (hasKsunextMgr) provider = "KernelSU-Next detected (manager installed)";
            else if (hasKsuDir && hasKsud) provider = "KernelSU state present (KSU family — exact variant unknown)";
            else if (hasKsuDir) provider = "KernelSU state present (variant unknown)";
            else provider = "unknown (root works, provider could not be determined)";
            mainHandler.post(() -> {
                if (tvRootProvider != null) tvRootProvider.setText("Root provider: " + provider);
                if (tvSuBinary != null) tvSuBinary.setText("su binary: " + su);
            });
        });
    }

    // --- 5.9.4 slot perks: notes, boot stats, checksums ---
    private String slotNote(String slot) {
        try {
            String n = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_NOTE_PREFIX + slot, "");
            return n == null ? "" : n;
        } catch (Exception ignored) { return ""; }
    }

    private void promptNoteEdit() {
        final String slot = selectedSlot;
        final EditText input = new EditText(this);
        input.setHint("e.g. test build - camera broken");
        input.setText(slotNote(slot));
        new AlertDialog.Builder(this)
            .setTitle("Note for slot '" + slot + "'")
            .setView(input)
            .setPositiveButton("Save", (dialog, which) -> {
                String note = input.getText().toString().trim();
                if (note.length() > 200) note = note.substring(0, 200);
                try {
                    android.content.SharedPreferences.Editor e = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit();
                    if (note.isEmpty()) e.remove(PREF_NOTE_PREFIX + slot);
                    else e.putString(PREF_NOTE_PREFIX + slot, note);
                    e.apply();
                } catch (Exception ignored) {}
                refreshSlotInfo();
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    // Counts takeover LAUNCHES (the app cannot observe the guest finishing
    // boot from here, so a spawned takeover is what gets counted).
    private void recordBoot(String slot) {
        try {
            android.content.SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
            int n = prefs.getInt(PREF_BOOTS_PREFIX + slot, 0);
            prefs.edit().putString(PREF_LAST_BOOT, slot).putInt(PREF_BOOTS_PREFIX + slot, n + 1).apply();
        } catch (Exception ignored) {}
    }

    // 5.9.16: record a per-slot last-boot outcome (see
    // PREF_LAST_BOOT_OUTCOME_PREFIX). Safe to call from any thread
    // (SharedPreferences only); never overwrites the boot count.
    private void noteLastBootOutcome(String slot, String code) {
        if (slot == null || slot.isEmpty() || code == null) return;
        try {
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
                .putString(PREF_LAST_BOOT_OUTCOME_PREFIX + slot, code + "|" + System.currentTimeMillis()).apply();
        } catch (Exception ignored) {}
    }

    private static String lastBootOutcomeShort(String stored) {
        if (stored == null || stored.isEmpty()) return null;
        String code = stored.split("\\|")[0];
        switch (code) {
            case "home": return "home ✓";
            case "timeout": return "watchdog timeout";
            case "returned": return "returned";
            case "reboot": return "reboot";
            case "panic": return "kernel panic";
            default: return code;
        }
    }

    private static String lastBootOutcomeLong(String stored) {
        if (stored == null || stored.isEmpty()) return "never";
        String[] parts = stored.split("\\|");
        String code = parts[0];
        String when = "";
        if (parts.length > 1) {
            try { when = " (" + new java.util.Date(Long.parseLong(parts[1])).toString() + ")"; } catch (Exception ignored) {}
        }
        switch (code) {
            case "home": return "home reached" + when;
            case "timeout": return "watchdog timeout (no home in 10 min)" + when;
            case "returned": return "returned to One UI" + when;
            case "reboot": return "session ended by reboot / force-restart" + when;
            case "panic": return "kernel panic ended the session" + when;
            default: return code + when;
        }
    }

    // 5.9.16: slot reconcile, run once at launch (onCreate, after
    // refreshSlots is queued — both run on the executor, so this
    // runs after the refresh task). The old code had per-path
    // cleanup scattered across sweepStaleGuestMarkers, Return's
    // light path, deleteSlot and clean-slate, each with its own
    // idea of what "stale" means; this single routine is now the
    // authority for slot-record vs on-disk drift, and it REPLACES
    // those per-path cleanups where they conflict (they now only
    // handle their own operation's aftermath). It logs every repair
    // and repairs only what is provably drift:
    //  - prefs keyed to a slot whose directory no longer exists
    //    (note/boots/sha/density/share/guest-root/color/outcome)
    //    are pruned; a PREF_LAST_BOOT pointing at a gone slot is
    //    cleared; a selected slot that no longer exists falls back
    //    to Default (refreshSlots already does this on the UI side,
    //    this fixes the stored record too).
    //  - stale install temps (system.raw.new, .converted, .fitcheck
    //    leftovers) and stale framework_version files for slots
    //    with no installed image are deleted (temps are never user
    //    data; a framework_version without an image is a lie).
    //  - slot directories with invalid names are LOGGED ONLY, never
    //    deleted (a foreign dir under slots/ is not proven drift).
    //  - a mounted rootfs with NO guest processes and NO takeover
    //    script for that stage is a leftover mount, not a live
    //    guest: it is lazily unmounted via containerUnmountCmd and
    //    its marker cleared. A mount WITH processes or a running
    //    takeover script is left strictly alone — unmounting a live
    //    guest's rootfs would kill the session.
    // Nothing here runs while a guest is running for that slot
    // (the mount repair requires the process + script checks to
    // both come back empty first).
    private void reconcileSlots() {
        if (!isRootGranted) return;
        executor.execute(() -> {
            try {
                List<String> dirs = allStageDirs();
                java.util.Set<String> onDisk = new java.util.HashSet<>();
                onDisk.add(DEFAULT_SLOT);
                List<String> names = new ArrayList<>();
                runRootCmdCaptured("ls -d " + STAGE_DIR + "/slots/*/ 2>/dev/null", names);
                for (String ln : names) {
                    String t = ln.trim();
                    if (t.endsWith("/")) t = t.substring(0, t.length() - 1);
                    int slash = t.lastIndexOf('/');
                    String n = slash >= 0 ? t.substring(slash + 1) : t;
                    if (isValidSlotName(n)) onDisk.add(n);
                    else if (!n.isEmpty()) appendLog("Slot reconcile: directory under slots/ has an invalid name and is left alone (not a slot record): " + t);
                }
                android.content.SharedPreferences pr = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
                android.content.SharedPreferences.Editor e = pr.edit();
                boolean changed = false;
                // Prune per-slot prefs for slots that no longer exist
                // on disk. Slot names are [A-Za-z0-9_-], so a prefs
                // key scan by prefix is safe.
                java.util.Map<String, ?> all = pr.getAll();
                String[] prefixes = {PREF_NOTE_PREFIX, PREF_BOOTS_PREFIX, PREF_SHA_PREFIX,
                    PREF_DENSITY_PREFIX, PREF_SHARE_PREFIX, PREF_GUEST_ROOT_PREFIX,
                    PREF_COLOR_PREFIX, PREF_LAST_BOOT_OUTCOME_PREFIX};
                for (String key : all.keySet()) {
                    for (String pfx : prefixes) {
                        if (key.startsWith(pfx)) {
                            String slot = key.substring(pfx.length());
                            if (!onDisk.contains(slot)) {
                                e.remove(key);
                                changed = true;
                                appendLog("Slot reconcile: pruned stale record '" + key + "' (slot '" + slot + "' no longer exists on disk).");
                            }
                            break;
                        }
                    }
                }
                String last = pr.getString(PREF_LAST_BOOT, null);
                if (last != null && !onDisk.contains(last)) { e.remove(PREF_LAST_BOOT); changed = true; appendLog("Slot reconcile: cleared last-booted slot '" + last + "' (slot no longer exists)."); }
                if (changed) e.apply();
                // Per-slot disk drift: stale temps, stale
                // framework_version, leftover mounts.
                for (String d : dirs) {
                    String slot = slotDisplayName(d);
                    List<String> hasRaw = new ArrayList<>();
                    runRootCmdCaptured("[ -f " + d + "/system.raw ] && echo YES || echo NO", hasRaw);
                    boolean hasImage = false;
                    for (String h : hasRaw) if ("YES".equals(h.trim())) { hasImage = true; break; }
                    List<String> temps = new ArrayList<>();
                    runRootCmdCaptured("for t in " + d + "/system.raw.new " + d + "/system.raw.converted " + d + "/.fitcheck_mnt" + (hasImage ? "" : " " + d + "/framework_version") + "; do [ -e \"$t\" ] && echo STALE; done", temps);
                    if (!temps.isEmpty()) {
                        runRootCmdDrained("rm -f " + d + "/system.raw.new " + d + "/system.raw.converted " + (hasImage ? "" : d + "/framework_version ") + "2>/dev/null; rm -rf " + d + "/.fitcheck_mnt 2>/dev/null");
                        appendLog("Slot reconcile: removed " + temps.size() + " stale temp file(s) for slot '" + slot + "'" + (hasImage ? "." : " (slot has no installed image, so its stale framework_version went too)."));
                    }
                    List<String> mounted = new ArrayList<>();
                    runRootCmdCaptured("mount | grep -q '" + d + "/rootfs ' && echo MOUNTED || echo NOMOUNT", mounted);
                    boolean isMounted = false;
                    for (String m : mounted) if ("MOUNTED".equals(m.trim())) { isMounted = true; break; }
                    if (!isMounted) continue;
                    // Mounted: live guest, or leftover? Live needs
                    // guest processes or a takeover script for this
                    // stage; neither present means leftover. Guest
                    // processes are identified by their /proc root
                    // pointing at this slot's rootfs — a NAME check
                    // (ps | grep system_server) would be wrong here,
                    // because the HOST's own system_server runs under
                    // that name whenever the phone is in One UI, and
                    // it would veto every legitimate leftover repair.
                    List<String> procs = new ArrayList<>();
                    runRootCmdCaptured("for p in /proc/[0-9]*; do [ \"$(readlink \"$p/root\" 2>/dev/null)\" = \"" + d + "/rootfs\" ] && echo GUESTPROC && break; done", procs);
                    List<String> takeover = new ArrayList<>();
                    runRootCmdCaptured("ps -ef 2>/dev/null | grep -a -F '" + d + "' | grep -a -E 'switch_to_gsi|master_prepare|master_inner' | grep -a -v grep | head -5", takeover);
                    if (!procs.isEmpty() || !takeover.isEmpty()) continue;
                    appendLog("Slot reconcile: slot '" + slot + "' has a mounted rootfs but no guest processes and no takeover script — treating it as a leftover mount and unmounting it.");
                    runRootCmdDrained(containerUnmountCmd(d));
                    runRootCmdDrained("rm -f " + d + "/.guest_running 2>/dev/null");
                    appendLog("Slot reconcile: leftover rootfs mount for slot '" + slot + "' unmounted; marker cleared.");
                }
            } catch (Exception ex) {
                appendLog("Slot reconcile failed (no repairs applied beyond those already logged): " + ex.getMessage());
            }
        });
    }

    private void triggerChecksum(final String slot, final String raw, final String cacheKey) {
        // Called from inside a refreshSlotInfo executor task; the compute
        // itself is queued on the same single-thread executor, so it runs
        // after the current task — never concurrently with another refresh.
        if (cacheKey.equals(checksumComputingKey)) return;
        checksumComputingKey = cacheKey;
        executor.execute(() -> {
            String hex = null;
            try {
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "command -v sha256sum >/dev/null 2>&1 && sha256sum " + raw + " 2>/dev/null | cut -d' ' -f1 || echo SHA_UNAVAILABLE"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line = r.readLine();
                p.waitFor();
                if (line != null) {
                    line = line.trim();
                    if (line.matches("[0-9a-f]{64}")) hex = line;
                }
            } catch (Exception ignored) {}
            final String fHex = hex;
            final String fSlot = slot;
            final String fKey = cacheKey;
            mainHandler.post(() -> {
                if (fKey.equals(checksumComputingKey)) checksumComputingKey = null;
                if (!fSlot.equals(selectedSlot) || tvInfoSha == null) return;
                if (fHex != null) {
                    try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putString(PREF_SHA_PREFIX + fSlot, fKey + ":" + fHex).apply(); } catch (Exception ignored) {}
                    tvInfoSha.setText("SHA-256: " + fHex);
                } else {
                    tvInfoSha.setText("SHA-256: unavailable (no sha256sum on device)");
                }
            });
        });
    }

    // Selected-slot GSI details card. Image size + format come from the
    // image file itself (magic reads, no mount). OS details come from
    // build.prop ONLY when this slot's guest is currently booted, i.e. its
    // rootfs is mounted — otherwise the card says so instead of guessing.
    // 5.9.5-INT-START
    private void shareLog() {
        try {
            String text = (tvConsoleLog != null) ? tvConsoleLog.getText().toString() : "";
            if (text.isEmpty()) text = "GSI Loader Samsung log (empty).";
            android.content.Intent it = new android.content.Intent(android.content.Intent.ACTION_SEND);
            it.setType("text/plain");
            it.putExtra(android.content.Intent.EXTRA_SUBJECT, "GSI Loader Samsung log");
            it.putExtra(android.content.Intent.EXTRA_TEXT, text);
            startActivity(android.content.Intent.createChooser(it, "Share log"));
        } catch (Exception e) {
            appendLog("Share log failed: " + e.getMessage());
        }
    }
    private int slotColorForSlot(String slot) {
        try { return getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getInt(PREF_COLOR_PREFIX + slot, 0xFF888888); } catch (Exception e) { return 0xFF888888; }
    }
    private void applySlotColor() {
        try {
            if (vSlotColor != null) vSlotColor.setBackgroundColor(slotColorForSlot(selectedSlot));
        } catch (Exception ignored) {}
    }
    private void promptSlotColor() {
        final String slot = selectedSlot;
        final String[] names = {"Default gray", "Cyan", "Green", "Amber", "Purple", "Red"};
        final int[] colors = {0xFF888888, 0xFF00BCD4, 0xFF4CAF50, 0xFFFFB300, 0xFF9C6BFF, 0xFFF44336};
        int cur = slotColorForSlot(slot); int checked = 0;
        for (int i = 0; i < colors.length; i++) if (colors[i] == cur) checked = i;
        new AlertDialog.Builder(this)
            .setTitle("Color label for slot '" + slot + "'")
            .setSingleChoiceItems(names, checked, (dialog, which) -> {
                try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putInt(PREF_COLOR_PREFIX + slot, colors[which]).apply(); } catch (Exception ignored) {}
                applySlotColor();
                dialog.dismiss();
            })
            .setNegativeButton("Cancel", null)
            .show();
    }
    // 5.9.5-INT-END

    private void refreshSlotInfo() {
        final String slot = selectedSlot;
        final String dir = currentSlotDir();
        final String raw = currentSystemRaw();
        final String rootfs = currentRootfs();
        executor.execute(() -> {
            String sizeText = "Image: not installed";
            String formatText = "Format: —";
            String osText = "OS: boot the slot to read its build.prop";
            long sz = -1;
            String mt = "0";
            try {
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "if [ ! -f " + raw + " ]; then echo 'INFO_MISSING'; exit 0; fi; "
                    + "SZ=$(stat -c %s " + raw + " 2>/dev/null || echo 0); echo \"INFO_SIZE:$SZ\"; "
                    + "M0=$(od -An -tx1 -N4 " + raw + " 2>/dev/null | tr -d ' \\n'); echo \"INFO_M0:$M0\"; "
                    + "ME=$(dd if=" + raw + " bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \\n'); echo \"INFO_ME:$ME\"; "
                    + "MX=$(dd if=" + raw + " bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \\n'); echo \"INFO_MX:$MX\"; "
                    + "MT=$(stat -c %Y " + raw + " 2>/dev/null || echo 0); echo \"INFO_MT:$MT\"; "
                    + "if mount | grep -q '" + rootfs + " '; then "
                    + "grep -m1 '^ro.build.display.id=' \"" + rootfs + "/system/build.prop\" 2>/dev/null | cut -d= -f2- | sed 's/^/INFO_OS:/'; "
                    + "grep -m1 '^ro.build.version.release=' \"" + rootfs + "/system/build.prop\" 2>/dev/null | cut -d= -f2- | sed 's/^/INFO_REL:/'; fi"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line, os = null, rel = null;
                String m0 = "", me = "", mx = "";
                while ((line = r.readLine()) != null) {
                    if (line.startsWith("INFO_SIZE:")) { try { sz = Long.parseLong(line.substring(10).trim()); } catch (Exception ignored) {} }
                    else if (line.startsWith("INFO_M0:")) m0 = line.substring(8).trim();
                    else if (line.startsWith("INFO_ME:")) me = line.substring(8).trim();
                    else if (line.startsWith("INFO_MX:")) mx = line.substring(8).trim();
                    else if (line.startsWith("INFO_OS:")) os = line.substring(8).trim();
                    else if (line.startsWith("INFO_REL:")) rel = line.substring(9).trim();
                    else if (line.startsWith("INFO_MT:")) mt = line.substring(8).trim();
                }
                p.waitFor();
                if (sz >= 0) {
                    sizeText = "Image: " + (sz / 1048576) + " MB";
                    if ("3aff26ed".equals(m0)) formatText = "Format: sparse (install converts it automatically)";
                    else if ("e2e1f5e0".equals(me)) formatText = "Format: EROFS";
                    else if ("53ef".equals(mx)) formatText = "Format: ext4";
                    else formatText = "Format: unknown";
                }
                if (os != null && !os.isEmpty()) {
                    osText = "OS: " + os + ((rel != null && !rel.isEmpty()) ? " (Android " + rel + ")" : "");
                }
            } catch (Exception ignored) {}
            // Perks (prefs reads are safe off the main thread).
            String note = slotNote(slot);
            final String fNote = (note == null || note.isEmpty()) ? "Note: \u2014" : "Note: " + note;
            int boots = 0;
            String lastOutcome = null;
            try {
                android.content.SharedPreferences pr = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
                boots = pr.getInt(PREF_BOOTS_PREFIX + slot, 0);
                // 5.9.16: per-slot last-boot OUTCOME (home / watchdog
                // timeout / returned / reboot / panic), not
                // PREF_LAST_BOOT — that pref stores a slot NAME, and
                // the old code displayed that name as if it were a
                // date ("Last booted: Default"), which was wrong for
                // every slot. Never-booted slots show "never".
                lastOutcome = pr.getString(PREF_LAST_BOOT_OUTCOME_PREFIX + slot, null);
            } catch (Exception ignored) {}
            final String fBoots = "Boots: " + boots + " \u2022 Last boot: " + lastBootOutcomeLong(lastOutcome);
            // Checksum: cached by size:mtime so a multi-GB rehash only
            // happens when the image actually changed. Missing file -> dash.
            final String fSha;
            if (sz < 0) {
                fSha = "SHA-256: \u2014";
            } else {
                String cacheKey = sz + ":" + mt;
                String cached = null;
                try { cached = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_SHA_PREFIX + slot, null); } catch (Exception ignored) {}
                if (cached != null && cached.startsWith(cacheKey + ":")) {
                    fSha = "SHA-256: " + cached.substring(cacheKey.length() + 1);
                } else {
                    fSha = "SHA-256: computing\u2026";
                    triggerChecksum(slot, raw, cacheKey);
                }
            }
            // 5.9.5-INT-START: storage breakdown (raw + data + snapshots + backups).
            String storageText = "Storage: \u2014";
            try {
                Process ps = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "for d in \"" + raw + "\" \"" + dir + "/data\" \"" + dir + "/snapshots\" \"" + dir + "/backups\"; do "
                    + "if [ -e \"$d\" ]; then du -sb \"$d\" 2>/dev/null | cut -f1; else echo 0; fi; done"});
                BufferedReader rs = new BufferedReader(new InputStreamReader(ps.getInputStream()));
                long[] vals = {0, 0, 0, 0}; int vi = 0; String ls;
                while ((ls = rs.readLine()) != null && vi < 4) { try { vals[vi] = Long.parseLong(ls.trim()); } catch (Exception ignored) {} vi++; }
                ps.waitFor();
                storageText = "Storage: image " + (vals[0] / 1048576) + " MB \u2022 data " + (vals[1] / 1048576) + " MB \u2022 snapshots " + (vals[2] / 1048576) + " MB \u2022 backups " + (vals[3] / 1048576) + " MB";
            } catch (Exception ignored) {}
            // 5.9.5-INT-END
            final String fSize = sizeText, fFormat = formatText, fOs = osText, fStorage = storageText;
            mainHandler.post(() -> {
                // 5.9.5-APP-START: boot-menu summary + framework detection.
                refreshBootMenuInfo(fSize, fBoots, fNote);
                detectFrameworkVersion();
                // 5.9.5-APP-END
                if (tvInfoSlot != null) tvInfoSlot.setText("Slot: " + slot + (slot.equals(DEFAULT_SLOT) ? " (original install)" : ""));
                if (tvInfoOs != null) tvInfoOs.setText(fOs);
                if (tvInfoSize != null) tvInfoSize.setText(fSize);
                if (tvInfoFormat != null) tvInfoFormat.setText(fFormat);
                if (tvInfoNote != null) tvInfoNote.setText(fNote);
                if (tvInfoBoots != null) tvInfoBoots.setText(fBoots);
                if (tvInfoSha != null) tvInfoSha.setText(fSha);
                // 5.9.5-INT-START: color dot + storage breakdown.
                applySlotColor();
                if (tvInfoStorage != null) tvInfoStorage.setText(fStorage);
                // 5.9.5-INT-END
            });
        });
    }

    private void checkImageStatus() {
        executor.execute(() -> {
            try {
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", "[ -f " + currentSystemRaw() + " ] && ls -lh " + currentSystemRaw() + " || echo 'MISSING'; [ -f " + currentSystemRaw() + ".bak ] && echo BAK_YES || echo BAK_NO"});
                BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String out = reader.readLine();
                String bakLine = reader.readLine();
                p.waitFor();
                final boolean hasBak = "BAK_YES".equals(bakLine != null ? bakLine.trim() : "");

                mainHandler.post(() -> {
                    refreshSlotInfo();
                    if (out != null && !out.contains("MISSING") && !out.trim().isEmpty()) {
                        imageInstalled = true;
                        tvImageStatus.setText("Guest system: Installed & ready (" + out.trim().replaceAll("\\s+", " ") + ")");
                        tvImageStatus.setTextColor(Color.parseColor("#A5D6A7"));
                        btnInstallGsi.setText("Reinstall GSI");
                        btnBootGsi.setEnabled(true);
                        btnBootGsi.setAlpha(1.0f);
                    } else {
                        imageInstalled = false;
                        tvImageStatus.setText("Guest system: Not installed (no system image for slot '" + selectedSlot + "' — tap Install first"
                                + (hasBak ? "; a backup file exists, so Restore backup can bring a system back" : "") + ")");
                        tvImageStatus.setTextColor(Color.parseColor("#FFB4AB"));
                        btnInstallGsi.setText("Install GSI");
                        btnBootGsi.setEnabled(false);
                        btnBootGsi.setAlpha(0.5f);
                    }
                });
            } catch (Exception e) {
                mainHandler.post(() -> tvImageStatus.setText("Image Check Error: " + e.getMessage()));
            }
        });
    }

    // 5.9.16: SHA-256 helpers for the asset/engine hash checks.
    // Streaming (32 KB buffer) so multi-MB jars never load fully
    // into memory; returns null on any error (caller treats null
    // as "no usable hash" and re-extracts / re-copies, never as a
    // match).
    private static String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) sb.append(String.format("%02x", b & 0xFF));
        return sb.toString();
    }

    private static String sha256HexFile(File f) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            try (InputStream in = new FileInputStream(f)) {
                byte[] buf = new byte[32768];
                int n;
                while ((n = in.read(buf)) != -1) md.update(buf, 0, n);
            }
            return bytesToHex(md.digest());
        } catch (Exception e) {
            return null;
        }
    }

    private void extractAssets() {
        // 5.9.11: incremental + guarded. Previously this re-extracted
        // every non-jar asset on EVERY launch (and twice per launch:
        // once from onCreate, once after the root check) — tens of MB
        // of APK I/O plus a full root re-sync to STAGE_DIR, every
        // cold start, for files that had not changed. Now unchanged
        // assets are skipped (see the loop), a version change still
        // forces a full re-extract, and concurrent calls collapse
        // into one run. assetsReady gates Install/Boot so no action
        // runs from a half-unpacked engine; it is set even on
        // partial failure (per-asset errors are logged, as before)
        // so one bad asset can never brick the app behind the gate.
        if (assetsExtracting) return;
        assetsExtracting = true;
        assetsReady = false;
        executor.execute(() -> {
            try {
            // NOTE: extracting the patched jars/apk only puts inert files on
            // disk. Nothing is BOUND over a GSI's framework unless
            // master_prepare.sh sees the matching flag in gsi_flags.conf
            // (see writeGsiFlagsFile). The bind decision lives in the script,
            // not in this list.
            String[] assets = {
                "switch_to_gsi.sh", "return_to_oneui.sh",
                "master_prepare.sh", "master_inner.sh",
                "zygote_exec", "clean_apex_info_list.xml",
                "services_patched.jar", "framework_patched.jar",
                "7zz", "PermissionController_patched.apk", "install_image.sh",
                // 5.9.5-INT-START: new engine scripts + converter.
                "guards.sh", "snapshot_slot.sh", "rollback_slot.sh",
                "backup_slot.sh", "verify_backup.sh", "guest_root.sh",
                "guest_root_shell.sh", "battery_guard.sh", "preflight_host.sh",
                "check_slot_guard.sh", "simg2img",
                // 5.9.10: read-only image inspector (see inspectGsi()).
                "inspect_image.sh",
                // 5.9.11: boot watchdog (started by switch_to_gsi.sh;
                // synced into STAGE_DIR by the loop below, and into
                // the slot dir by bootGsi's sync).
                "boot_watchdog.sh",
                // 5.9.13: boot diagnostics (watchdog-timeout bundle)
                // and pstore check (post-reboot panic verdict). Both
                // are synced to the slot dir by bootGsi's sync loop.
                "boot_diagnostics.sh", "pstore_check.sh"
                // 5.9.5-INT-END
            };
            File filesDir = getFilesDir();
            // 5.9.6: jars were skipped whenever ANY copy existed on disk,
            // so an updated jar shipped in a new app version never
            // replaced the old one. Force a full re-extract whenever the
            // app version changes (once per upgrade, not every launch).
            String bundleVersion = "";
            try {
                bundleVersion = getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
            } catch (Exception ignored) {}
            boolean forceAll = false;
            try {
                String saved = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_ASSETS_VERSION, null);
                forceAll = bundleVersion != null && !bundleVersion.isEmpty() && !bundleVersion.equals(saved);
            } catch (Exception ignored) {}
            final String fBundleVersion = bundleVersion;
            final boolean fForceAll = forceAll;
            SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
            int copied = 0, skipped = 0;
            for (String asset : assets) {
                File target = new File(filesDir, asset);
                // 5.9.16: SHA-256 skip, NOT length-only. The old
                // rules (jars: exists-and-nonempty; others: length
                // matches the recorded length) skipped a same-length
                // stale/corrupt asset forever. Now the versioned
                // hash record "asset_sha_<asset>" =
                // "<appVersion>:<sha256>" is the skip test: the
                // on-disk file is hashed and must equal the recorded
                // hash for THIS app version, or it is re-extracted.
                // A version change (forceAll) still re-extracts
                // everything and records fresh hashes. No usable
                // record (pre-5.9.16 install) also re-extracts once
                // and records a hash, so the next launch is covered.
                // Cost: hashing ~60 MB of jars per launch on the
                // background executor — seconds, and the price of
                // never booting from a corrupt patched jar again.
                if (!fForceAll && target.exists() && target.length() > 0) {
                    String recorded = prefs.getString("asset_sha_" + asset, null);
                    if (recorded != null && fBundleVersion != null
                            && recorded.startsWith(fBundleVersion + ":")) {
                        String wantHex = recorded.substring(fBundleVersion.length() + 1);
                        String gotHex = sha256HexFile(target);
                        if (wantHex.equals(gotHex)) { skipped++; continue; }
                        appendLog("Asset hash mismatch for " + asset + " — re-extracting (length alone would have skipped it).");
                    }
                }
                try (InputStream in = getAssets().open(asset);
                     OutputStream out = new FileOutputStream(target)) {
                    MessageDigest md = MessageDigest.getInstance("SHA-256");
                    byte[] buffer = new byte[32768];
                    int read; long written = 0;
                    while ((read = in.read(buffer)) != -1) {
                        out.write(buffer, 0, read);
                        md.update(buffer, 0, read);
                        written += read;
                    }
                    target.setExecutable(true, false);
                    target.setReadable(true, false);
                    String hex = bytesToHex(md.digest());
                    try {
                        prefs.edit().putString("asset_len_" + asset, Long.toString(written))
                            .putString("asset_sha_" + asset, (fBundleVersion != null ? fBundleVersion : "") + ":" + hex).apply();
                    } catch (Exception ignored) {}
                    copied++;
                } catch (Exception e) {
                    appendLog("Error unpacking " + asset + ": " + e.getMessage());
                }
            }
            // 5.9.11: stage sync is now syncEngineToStageSync()
            // (size-checked big files, scripts always copied).
            if (isRootGranted) {
                syncEngineToStageSync();
            }
            if (fForceAll && fBundleVersion != null && !fBundleVersion.isEmpty()) {
                try { prefs.edit().putString(PREF_ASSETS_VERSION, fBundleVersion).apply(); } catch (Exception ignored) {}
            }
            if (!assetsLogShown) { appendLog("GSI Loader engine assets ready (" + copied + " unpacked, " + skipped + " already up to date)."); assetsLogShown = true; }
            } finally {
                assetsReady = true;
                assetsExtracting = false;
            }
        });
    }


    // ================= 5.9.7: UI styles, progress, guide, motion ==============
    private int dp597(int dp) {
        return Math.round(dp * getResources().getDisplayMetrics().density);
    }

    private void setupUiStyleSelection() {
        if (rgUiStyle == null) return;
        try { uiStyle = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_UI_STYLE, "stage"); } catch (Exception ignored) { uiStyle = "stage"; }
        int checkId = R.id.rb_style_stage;
        if ("compact".equals(uiStyle)) checkId = R.id.rb_style_compact;
        else if ("focus".equals(uiStyle)) checkId = R.id.rb_style_focus;
        else if ("wide".equals(uiStyle)) checkId = R.id.rb_style_wide;
        rgUiStyle.check(checkId);
        rgUiStyle.setOnCheckedChangeListener((group, checkedId) -> {
            String next = "stage";
            if (checkedId == R.id.rb_style_compact) next = "compact";
            else if (checkedId == R.id.rb_style_focus) next = "focus";
            else if (checkedId == R.id.rb_style_wide) next = "wide";
            if (!next.equals(uiStyle)) {
                uiStyle = next;
                moreToolsExpanded = false;
                try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putString(PREF_UI_STYLE, next).apply(); } catch (Exception ignored) {}
                applyUiStyle();
            }
        });
    }

    private void setSectionVisible(LinearLayout s, boolean vis) {
        if (s != null) s.setVisibility(vis ? View.VISIBLE : View.GONE);
    }

    private void applyUiStyle() {
        if (rootContainer == null) return;
        // Reset: everything visible first (unrooted section left alone: its
        // visibility is owned by the root check, not by the style).
        LinearLayout[] all = {sectionHeader, sectionDevwarn, sectionStatus, sectionHero,
                sectionPatches, sectionSlots, sectionSnapshots, sectionGuest, sectionSafety,
                sectionLog, sectionLook};
        for (LinearLayout s : all) setSectionVisible(s, true);
        if (btnMoreTools != null) btnMoreTools.setVisibility(View.GONE);
        int pad = dp597(20), top = dp597(36), cardPad = dp597(20), gap = dp597(16), logH = dp597(180);
        int btnH = dp597(56);
        boolean focus = "focus".equals(uiStyle);
        if ("compact".equals(uiStyle)) {
            pad = dp597(12); top = dp597(16); cardPad = dp597(12); gap = dp597(8); logH = dp597(140); btnH = dp597(48);
            if (sectionHero != null) sectionHero.setBackgroundResource(R.drawable.card_skin);
        } else if ("wide".equals(uiStyle)) {
            pad = dp597(24); top = dp597(40); cardPad = dp597(24); gap = dp597(20); logH = dp597(260); btnH = dp597(64);
            if (sectionHero != null) sectionHero.setBackgroundResource(R.drawable.card_hero);
        } else {
            if (sectionHero != null) sectionHero.setBackgroundResource(R.drawable.card_hero);
            // Restore the default order if a previous Focus pass moved the
            // hero above status (hero belongs after status/unrooted).
            if (sectionHero != null && sectionStatus != null
                    && rootContainer.indexOfChild(sectionHero) >= 0
                    && rootContainer.indexOfChild(sectionHero) < rootContainer.indexOfChild(sectionStatus)) {
                rootContainer.removeView(sectionHero);
                int idx = (sectionUnrooted != null) ? rootContainer.indexOfChild(sectionUnrooted) : -1;
                rootContainer.addView(sectionHero, idx >= 0 ? idx + 1 : rootContainer.indexOfChild(sectionStatus) + 1);
            }
        }
        if (focus) {
            // Arrangement change, not a color swap: hero jumps above status,
            // and secondary sections hide behind More tools. Look stays
            // visible so the user can always leave Focus.
            if (sectionHero != null && sectionStatus != null) {
                rootContainer.removeView(sectionHero);
                int idx = rootContainer.indexOfChild(sectionStatus);
                rootContainer.addView(sectionHero, Math.max(0, idx));
            }
            setSectionVisible(sectionPatches, false);
            setSectionVisible(sectionSlots, false);
            setSectionVisible(sectionSnapshots, false);
            setSectionVisible(sectionGuest, false);
            setSectionVisible(sectionSafety, false);
            if (btnMoreTools != null) { btnMoreTools.setVisibility(View.VISIBLE); btnMoreTools.setText("More tools"); }
        } else if (moreToolsExpanded) {
            moreToolsExpanded = false;
        }
        rootContainer.setPadding(pad, top, pad, dp597(48));
        LinearLayout[] cards = {sectionDevwarn, sectionStatus, sectionHero, sectionPatches,
                sectionSlots, sectionSnapshots, sectionGuest, sectionSafety, sectionLog, sectionLook};
        for (LinearLayout s : cards) {
            if (s == null) continue;
            s.setPadding(cardPad, cardPad, cardPad, cardPad);
            try {
                LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) s.getLayoutParams();
                if (lp != null) { lp.topMargin = gap; s.setLayoutParams(lp); }
            } catch (Exception ignored) {}
        }
        if (btnInstallGsi != null) {
            try { LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) btnInstallGsi.getLayoutParams(); if (lp != null) { lp.height = btnH; btnInstallGsi.setLayoutParams(lp); } } catch (Exception ignored) {}
        }
        if (btnBootGsi != null) {
            try { LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) btnBootGsi.getLayoutParams(); if (lp != null) { lp.height = btnH; btnBootGsi.setLayoutParams(lp); } } catch (Exception ignored) {}
        }
        if (tvConsoleLog != null) {
            try { LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) tvConsoleLog.getLayoutParams(); if (lp != null) { lp.height = logH; tvConsoleLog.setLayoutParams(lp); } } catch (Exception ignored) {}
        }
    }

    private void toggleMoreTools() {
        moreToolsExpanded = !moreToolsExpanded;
        setSectionVisible(sectionPatches, moreToolsExpanded);
        setSectionVisible(sectionSlots, moreToolsExpanded);
        setSectionVisible(sectionSnapshots, moreToolsExpanded);
        setSectionVisible(sectionGuest, moreToolsExpanded);
        setSectionVisible(sectionSafety, moreToolsExpanded);
        if (btnMoreTools != null) btnMoreTools.setText(moreToolsExpanded ? "Fewer tools" : "More tools");
    }

    // Operation progress bar (hero card): determinate pct 0-100, or -1 for
    // indeterminate. Never blocks: it only reflects work already running.
    private void setOperationProgress(final int pct, final String label, final boolean visible) {
        mainHandler.post(() -> {
            if (pbOperation == null || tvOperationProgress == null) return;
            if (!visible) { pbOperation.setVisibility(View.GONE); tvOperationProgress.setVisibility(View.GONE); return; }
            pbOperation.setVisibility(View.VISIBLE);
            tvOperationProgress.setVisibility(View.VISIBLE);
            pbOperation.setIndeterminate(pct < 0);
            if (pct >= 0) { pbOperation.setMax(100); pbOperation.setProgress(Math.min(100, pct)); }
            if (label != null) tvOperationProgress.setText(label);
        });
    }

    // 5.9.11: per-function progress bars (user-requested: one colorful
    // bar per major function, not a single shared bar). All helpers
    // post to mainHandler, so they are safe from any thread. A bar
    // is VISIBLE only while its function runs; completion hides it
    // (the log line is the permanent record).
    private void showFuncBar(final ProgressBar bar, final TextView label, final String text) {
        mainHandler.post(() -> {
            if (bar != null) { bar.setVisibility(View.VISIBLE); bar.setIndeterminate(true); }
            if (label != null) { label.setVisibility(View.VISIBLE); label.setText(text); }
        });
    }

    private void showFuncBarPct(final ProgressBar bar, final TextView label, final int pct, final String text) {
        mainHandler.post(() -> {
            if (bar != null) { bar.setVisibility(View.VISIBLE); bar.setIndeterminate(false); bar.setMax(100); bar.setProgress(Math.min(100, Math.max(0, pct))); }
            if (label != null) { label.setVisibility(View.VISIBLE); label.setText(text); }
        });
    }

    private void hideFuncBar(final ProgressBar bar, final TextView label) {
        mainHandler.post(() -> {
            if (bar != null) bar.setVisibility(View.GONE);
            if (label != null) label.setVisibility(View.GONE);
        });
    }

    // 5.9.11: run a task with its own colorful bar: the bar shows on
    // submission (instant tap feedback) and hides in a finally, so
    // EVERY exit path (success, failure, early return) hides it —
    // a bar can never stick on screen. The single-thread executor
    // still serializes the work itself (see assetsReady comment).
    private void runBarTask(final ProgressBar bar, final TextView label, final String text, final Runnable task) {
        showFuncBar(bar, label, text);
        executor.execute(() -> {
            try { task.run(); } finally { hideFuncBar(bar, label); }
        });
    }

    // 5.9.11: stream the return log (restore_app.log) into the app log
    // + the Return/Reboot bar. The return script runs detached (it
    // restarts the host display stack), so this polls its log the
    // same way streamBootProgress polls the takeover log. Stops at
    // RETURN_OK / RETURN_PARTIAL or after 120s. For the reboot
    // variant the phone reboots mid-poll and the task simply dies
    // with the app — that is the expected end, not an error.
    private void streamReturnProgress(final String logPath, final ProgressBar bar, final TextView label, final boolean isReboot) {
        // 5.9.16: pollExecutor (see streamBootProgress): a hung
        // return stream must never wedge the root-op queue.
        pollExecutor.execute(() -> {
            try {
                int total = 0;
                int stage = 0;
                for (int poll = 0; poll < 40; poll++) { // 40 x 3s = 120s
                    Thread.sleep(3000);
                    List<String> fresh = new ArrayList<>();
                    runRootCmdCaptured("tail -n +" + (total + 1) + " " + logPath + " 2>/dev/null", fresh);
                    for (String line : fresh) {
                        appendLog(line);
                        if (line.contains("RETURN_OK")) {
                            showFuncBarPct(bar, label, 100, isReboot ? "Return complete — rebooting now…" : "One UI restored.");
                            appendLog(isReboot ? "Return complete — the phone reboots now." : "One UI restore verified (RETURN_OK).");
                            // 5.9.16: record the returning slot's
                            // outcome. If the Activator log says the
                            // guest reached home before this return,
                            // the outcome is home (the return just
                            // ended a good session); otherwise it is
                            // a plain return. RETURN_PARTIAL records
                            // nothing — a partial restore is not a
                            // clean session end.
                            if (returningSlot != null) {
                                List<String> hc = new ArrayList<>();
                                runRootCmdCaptured("grep -q 'Home activated!' /data/local/tmp/ui_activator.log 2>/dev/null && echo HOME || echo NOHOME", hc);
                                boolean home = false;
                                for (String h : hc) if ("HOME".equals(h.trim())) { home = true; break; }
                                noteLastBootOutcome(returningSlot, home ? "home" : "returned");
                                returningSlot = null;
                            }
                            hideFuncBar(bar, label);
                            return;
                        } else if (line.contains("RETURN_PARTIAL")) {
                            showFuncBarPct(bar, label, 100, "Return partial — see log.");
                            appendLog("Return finished PARTIAL (some steps failed — see the restore log above). If One UI looks wrong, reboot the phone.");
                            hideFuncBar(bar, label);
                            return;
                        } else if (line.contains("[1/5]") && stage < 20) {
                            stage = 20; showFuncBarPct(bar, label, 20, "Returning… (step 1 of 5)");
                        } else if (line.contains("[2/5]") && stage < 40) {
                            stage = 40; showFuncBarPct(bar, label, 40, "Returning… (step 2 of 5)");
                        } else if (line.contains("[3/5]") && stage < 60) {
                            stage = 60; showFuncBarPct(bar, label, 60, "Returning… (step 3 of 5)");
                        } else if (line.contains("[4/5]") && stage < 80) {
                            stage = 80; showFuncBarPct(bar, label, 80, "Returning… (step 4 of 5)");
                        } else if (line.contains("[5/5]") && stage < 90) {
                            stage = 90; showFuncBarPct(bar, label, 90, "Returning… (step 5 of 5)");
                        }
                    }
                    total += fresh.size();
                }
                showFuncBarPct(bar, label, 90, "Return still running — see log.");
                appendLog("Return still running after 2 minutes (check the restore log for where it is).");
            } catch (Exception e) {
                appendLog("Return progress streaming stopped: " + e.getMessage());
            }
        });
    }

    // 5.9.16: install-progress poller — the same pattern as
    // streamBootProgress, for install_image.sh's INSTALL_PROGRESS
    // markers in <slotDir>/install_progress.log (7zz extraction and
    // simg2img conversion ticks, every 5 s). Runs on pollExecutor
    // so a long install poll never wedges the root-op queue; it
    // only reads the append-only progress file and updates the
    // Download bar/text via mainHandler-posted helpers, so it is
    // safe against concurrent appends. Stops at the script's
    // "done"/"failed" marker, or after 30 min. WIRING NOTE for the
    // coordinator merge: the Install-path owner owns the call site
    // — call streamInstallProgress(slotDir) immediately before the
    // installImageCmd run in the download/install flow, and let
    // this poller stop itself on the done/failed marker. The
    // script side (markers + progress file) is already live, so a
    // local-file install only needs that one call added.
    private void streamInstallProgress(final String slotDir) {
        // 5.9.17: every poller run owns a generation. Completion
        // (success/failure) bumps the generation, so a late poller
        // post can never overwrite the final UI with a stale
        // "Installing: ..." line — the reported "installing vs
        // done" contradiction.
        final int myGen = installProgressGen.incrementAndGet();
        pollExecutor.execute(() -> {
            try {
                String logPath = slotDir + "/install_progress.log";
                int total = 0;
                for (int poll = 0; poll < 600; poll++) { // 600 x 3s = 30 min cap
                    Thread.sleep(3000);
                    List<String> fresh = new ArrayList<>();
                    runRootCmdCaptured("tail -n +" + (total + 1) + " " + logPath + " 2>/dev/null", fresh);
                    for (String line : fresh) {
                        if (line.contains("INSTALL_PROGRESS:")) {
                            final String msg = line.substring(line.indexOf("INSTALL_PROGRESS:") + "INSTALL_PROGRESS:".length()).trim();
                            mainHandler.post(() -> {
                                if (installProgressGen.get() != myGen) return;
                                if (tvDownloadProgress != null) tvDownloadProgress.setText("Installing: " + msg);
                                if (tvOperationProgress != null) tvOperationProgress.setText("Installing: " + msg);
                            });
                            // Exact terminal markers only: intermediate
                            // lines like "extraction done" must NOT stop
                            // the poller mid-install.
                            if (line.contains("INSTALL_PROGRESS: done") || line.contains("INSTALL_PROGRESS: failed")) return;
                        }
                    }
                    total += fresh.size();
                }
                if (installProgressGen.get() == myGen) appendLog("Install progress polling stopped after 30 minutes (the install script may still be running — check the log).");
            } catch (Exception e) {
                if (installProgressGen.get() == myGen) appendLog("Install progress streaming stopped: " + e.getMessage());
            }
        });
    }

    private void refreshInstallEnabled() {
        mainHandler.post(() -> {
            if (btnInstallGsi != null) {
                // 5.9.16: btn_skin_primary has NO disabled state in its
                // drawable, so a disabled Install used to look exactly
                // like an enabled one — a tap on it silently did nothing
                // and the user had no way to tell. Dim it like the Boot
                // button (alpha 0.5 when disabled) so "disabled" is
                // visible, not just behavioral.
                boolean enabled = !downloading && !pickerCopying;
                btnInstallGsi.setEnabled(enabled);
                btnInstallGsi.setAlpha(enabled ? 1.0f : 0.5f);
            }
        });
    }

    // Short, hardware-friendly motion only: 80ms press scale, ~220ms
    // entrance fade/slide. Nothing here gates or delays any operation.
    private void pressFeedback(final View v) {
        if (v == null) return;
        v.setOnTouchListener((view, ev) -> {
            int a = ev.getAction();
            if (a == android.view.MotionEvent.ACTION_DOWN) {
                view.animate().scaleX(0.96f).scaleY(0.96f).setDuration(80).start();
            } else if (a == android.view.MotionEvent.ACTION_UP || a == android.view.MotionEvent.ACTION_CANCEL) {
                view.animate().scaleX(1f).scaleY(1f).setDuration(120).start();
            }
            return false;
        });
    }

    private void wirePressFeedback() {
        pressFeedback(btnInstallGsi);
        pressFeedback(btnBootGsi);
        pressFeedback(btnReturnOneUI);
        pressFeedback(cardFlavorVanilla);
        pressFeedback(cardFlavorGapps);
        pressFeedback(cardCustom);
    }

    private void animateEntrance() {
        try {
            if (sectionHero != null) {
                sectionHero.setAlpha(0f); sectionHero.setTranslationY(24f);
                sectionHero.animate().alpha(1f).translationY(0f).setDuration(220).start();
            }
            if (sectionStatus != null) {
                sectionStatus.setAlpha(0f); sectionStatus.setTranslationY(24f);
                sectionStatus.animate().alpha(1f).translationY(0f).setDuration(220).setStartDelay(60).start();
            }
            if (sectionLog != null) {
                sectionLog.setAlpha(0f);
                sectionLog.animate().alpha(1f).setDuration(220).setStartDelay(120).start();
            }
        } catch (Exception ignored) {}
    }

    // ================= 5.9.14 =================
    // Experimental menu + fixed logs. The user asked for logs that
    // actually work and scroll, plus experimental features in their
    // own menu, styled by the app's own theme. Everything here is
    // diagnostic (read-only) except the live streams, which only
    // read log buffers. Nothing flashes, mounts, or boots anything
    // new. All of it needs temp root; without root the failure is
    // stated plainly instead of surfacing as a bare RUN_ERROR.

    private boolean requireRootForLogs(String what) {
        if (isRootGranted) return true;
        appendLog("Temp root isn't active — re-apply temp root first, then " + what + ". Without root the app can't read system or kernel logs, and that is why the log looked empty.");
        return false;
    }

    // 5.9.15: fancy Experimental menu — a themed dialog inflated
    // from dialog_experimental.xml (card_skin, btn_skin_tonal,
    // themePrimary text), so it follows the app's current skin.
    // Tapping a tool dismisses the menu and runs it; live streams
    // stop by reopening the menu and tapping the same tool again.
    private void showExperimentalMenu() {
        appendLog("🧪 Experimental — the lab. Fancy buttons, real diagnostics.");
        android.view.View v = getLayoutInflater().inflate(R.layout.dialog_experimental, null);
        final AlertDialog dlg = new AlertDialog.Builder(this).setView(v).create();
        v.findViewById(R.id.exp_kernel_log).setOnClickListener(b -> { dlg.dismiss(); kernelLogSnapshot(); });
        v.findViewById(R.id.exp_live_logcat_errors).setOnClickListener(b -> { dlg.dismiss(); toggleLiveStream("logcat", "logcat -b main -b system -b crash -v brief *:E", "errors only, so the crash lines stand out"); });
        v.findViewById(R.id.exp_live_dmesg).setOnClickListener(b -> { dlg.dismiss(); toggleLiveStream("dmesg", "dmesg -w", null); });
        v.findViewById(R.id.exp_diagnostics).setOnClickListener(b -> { dlg.dismiss(); runDiagnosticsNow(); });
        v.findViewById(R.id.exp_pstore).setOnClickListener(b -> { dlg.dismiss(); checkPstoreNow(); });
        v.findViewById(R.id.exp_guest_processes).setOnClickListener(b -> { dlg.dismiss(); guestProcesses(); });
        v.findViewById(R.id.exp_rescue_status).setOnClickListener(b -> { dlg.dismiss(); rescuePartyStatus(); });
        v.findViewById(R.id.exp_save_all).setOnClickListener(b -> { dlg.dismiss(); saveAllLogs(); });
        v.findViewById(R.id.exp_takeover_tail).setOnClickListener(b -> { dlg.dismiss(); takeoverLogTail(); });
        v.findViewById(R.id.exp_live_logcat_full).setOnClickListener(b -> { dlg.dismiss(); liveLogcatFull(); });
        v.findViewById(R.id.exp_rescue_toggle).setOnClickListener(b -> { dlg.dismiss(); rescuePartyToggle(); });
        v.findViewById(R.id.exp_device_info).setOnClickListener(b -> { dlg.dismiss(); deviceInfoDump(); });
        // 5.9.16: diagnostics-bundle export button, added in code
        // rather than in dialog_experimental.xml (that layout file
        // is outside this workstream's ownership). The inflated
        // root is a ScrollView holding one vertical LinearLayout;
        // the button is appended there, after the existing tools.
        try {
            android.widget.LinearLayout group = (android.widget.LinearLayout) ((android.widget.ScrollView) v).getChildAt(0);
            Button btnExport = new Button(this);
            btnExport.setText("Export diagnostics bundle");
            // Coordinator fix: setTextAllCaps() does not resolve against
            // this build's android.jar stub (verified via javap on both
            // android-34 and android-37.0 stubs), so use the equivalent
            // transformation removal directly — API-1 safe, same result.
            btnExport.setTransformationMethod(null);
            android.widget.LinearLayout.LayoutParams lp = new android.widget.LinearLayout.LayoutParams(
                    android.view.ViewGroup.LayoutParams.MATCH_PARENT, dp597(40));
            lp.topMargin = dp597(10);
            btnExport.setLayoutParams(lp);
            btnExport.setOnClickListener(b -> { dlg.dismiss(); exportDiagnosticsBundle(); });
            group.addView(btnExport);
        } catch (Exception ignored) {}
        v.findViewById(R.id.exp_close).setOnClickListener(b -> dlg.dismiss());
        dlg.show();
    }

    private void kernelLogSnapshot() {
        if (!requireRootForLogs("try the kernel log again")) return;
        executor.execute(() -> {
            List<String> lines = new ArrayList<>();
            runRootCmdCaptured("dmesg 2>/dev/null | tail -200", lines);
            appendLog("🐧 Kernel log (dmesg, last 200 lines):");
            if (lines.isEmpty()) appendLog("  (no kernel log lines — dmesg gave nothing back)");
            for (String l : lines) appendLog("  " + l);
            appendLog("— end kernel log —");
        });
    }

    private void toggleLiveStream(final String tag, final String cmd, final String note) {
        if (tag.equals(liveLogTag)) { stopLiveStream(); return; }
        stopLiveStream();
        if (!requireRootForLogs("start the live " + tag + " stream")) return;
        liveLogTag = tag;
        appendLog("▶ Live " + tag + " streaming" + (note != null ? " (" + note + ")" : "") + " — open Experimental again and tap it to stop.");
        final String want = tag;
        liveLogThread = new Thread(() -> {
            Process p = null;
            try {
                p = new ProcessBuilder(suBinary, "-c", cmd).start();
                liveLogProcess = p;
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                while ((line = r.readLine()) != null) {
                    if (Thread.currentThread().isInterrupted()) break;
                    if (!want.equals(liveLogTag)) break;
                    appendLog("[" + want + "] " + line);
                }
            } catch (Exception e) {
                appendLog("Live " + want + " stream ended: " + e.getMessage());
            } finally {
                if (p != null) p.destroy();
                if (want.equals(liveLogTag)) liveLogTag = null;
            }
        });
        liveLogThread.start();
    }

    private void stopLiveStream() {
        String tag = liveLogTag;
        liveLogTag = null;
        try { if (liveLogProcess != null) liveLogProcess.destroy(); } catch (Exception ignored) {}
        try { if (liveLogThread != null) liveLogThread.interrupt(); } catch (Exception ignored) {}
        liveLogProcess = null; liveLogThread = null;
        if (tag != null) appendLog("■ Live " + tag + " stopped.");
    }

    private void runDiagnosticsNow() {
        if (!requireRootForLogs("run diagnostics")) return;
        executor.execute(() -> {
            try {
                String dir = currentSlotDir();
                String script = new File(getFilesDir(), "boot_diagnostics.sh").getAbsolutePath();
                List<String> out = new ArrayList<>();
                runRootCmdCaptured("sh \"" + script + "\" \"" + dir + "\" 2>/dev/null", out);
                List<String> bundle = new ArrayList<>();
                runRootCmdCaptured("head -200 \"" + dir + "/boot_diagnostics.log\" 2>/dev/null", bundle);
                appendLog("--- Boot diagnostics for '" + selectedSlot + "' (on demand) ---");
                if (bundle.isEmpty()) appendLog("  (no diagnostics bundle — the script produced nothing for this slot)");
                for (String l : bundle) appendLog(l);
            } catch (Exception e) {
                appendLog("Diagnostics run failed: " + e.getMessage());
            }
        });
    }

    private void checkPstoreNow() {
        if (!requireRootForLogs("check the panic record")) return;
        executor.execute(() -> {
            String script = new File(getFilesDir(), "pstore_check.sh").getAbsolutePath();
            List<String> verdict = new ArrayList<>();
            runRootCmdCaptured("sh \"" + script + "\" 2>/dev/null", verdict);
            if (verdict.isEmpty()) appendLog("(panic-record check printed nothing — either already reported once, or no panic record exists)");
            for (String v : verdict) appendLog(v);
        });
    }

    private void guestProcesses() {
        if (!requireRootForLogs("list guest processes")) return;
        executor.execute(() -> {
            List<String> lines = new ArrayList<>();
            runRootCmdCaptured("ps -ef 2>/dev/null | grep -a -E 'system_server|zygote_exec|app_process|surfaceflinger' | grep -a -v grep | head -40", lines);
            appendLog("Guest processes (host-visible, same process table):");
            if (lines.isEmpty()) appendLog("  (none visible — the guest probably isn't running)");
            for (String l : lines) appendLog("  " + l);
        });
    }

    private void rescuePartyStatus() {
        if (!requireRootForLogs("read RescueParty status")) return;
        executor.execute(() -> {
            List<String> lines = new ArrayList<>();
            runRootCmdCaptured("getprop persist.sys.disable_rescue 2>/dev/null; getprop sys.rescue_boot_count 2>/dev/null", lines);
            String dis = lines.size() > 0 ? lines.get(0) : "unknown";
            String cnt = lines.size() > 1 ? lines.get(1) : "unknown";
            appendLog("RescueParty: disable_rescue=" + dis + ", rescue_boot_count=" + cnt + (("true".equals(dis)) ? " (crash-reboot path is OFF)" : " (crash-reboot path is LIVE — a crash-loop can reboot the phone)"));
        });
    }

    // 5.9.15: takeover-log tail — the same two logs the diagnostics
    // bundle reads, on demand, last 100 lines each.
    private void takeoverLogTail() {
        if (!requireRootForLogs("read the takeover log")) return;
        executor.execute(() -> {
            String dir = currentSlotDir();
            List<String> app = new ArrayList<>();
            runRootCmdCaptured("if [ -f \"" + dir + "/takeover_app.log\" ]; then tail -100 \"" + dir + "/takeover_app.log\"; else echo \"__MISSING__\"; fi 2>/dev/null", app);
            List<String> inner = new ArrayList<>();
            runRootCmdCaptured("if [ -f \"" + dir + "/data/takeover.log\" ]; then tail -100 \"" + dir + "/data/takeover.log\"; else echo \"__MISSING__\"; fi 2>/dev/null", inner);
            appendLog("--- Takeover log tail (slot '" + selectedSlot + "', last 100 lines each) ---");
            appendLog("takeover_app.log:");
            if (app.size() == 1 && "__MISSING__".equals(app.get(0))) appendLog("  (no takeover_app.log)");
            else if (app.isEmpty()) appendLog("  (empty file)");
            else for (String l : app) appendLog("  " + l);
            appendLog("data/takeover.log:");
            if (inner.size() == 1 && "__MISSING__".equals(inner.get(0))) appendLog("  (no data/takeover.log)");
            else if (inner.isEmpty()) appendLog("  (empty file)");
            else for (String l : inner) appendLog("  " + l);
        });
    }

    // 5.9.15: full live system log — same toggle behavior as the
    // error-only stream, but unfiltered, so it is very chatty.
    private void liveLogcatFull() {
        if ("logcat-full".equals(liveLogTag)) { stopLiveStream(); return; }
        appendLog("⚠ Full system log is chatty — every log line streams, not just errors.");
        toggleLiveStream("logcat-full", "logcat -v brief", "full stream, very chatty");
    }

    // 5.9.15: RescueParty toggle — flips persist.sys.disable_rescue
    // and reads it back, so the new value is proven, not assumed.
    private void rescuePartyToggle() {
        if (!requireRootForLogs("toggle RescueParty")) return;
        executor.execute(() -> {
            List<String> cur = new ArrayList<>();
            runRootCmdCaptured("getprop persist.sys.disable_rescue 2>/dev/null", cur);
            String now = cur.isEmpty() ? "" : cur.get(0).trim();
            String next = "true".equals(now) ? "false" : "true";
            List<String> back = new ArrayList<>();
            runRootCmdCaptured("setprop persist.sys.disable_rescue " + next + " 2>/dev/null; getprop persist.sys.disable_rescue 2>/dev/null", back);
            String after = back.isEmpty() ? "unknown" : back.get(back.size() - 1).trim();
            appendLog("RescueParty toggle: disable_rescue is now " + after + " (was " + (now.isEmpty() ? "unset" : now) + ").");
            if ("false".equals(after)) appendLog("⚠ Warning: crash-reboots are LIVE again — a crash-looping guest can reboot the phone.");
            else if ("true".equals(after)) appendLog("⚠ Warning: crash-reboots are stopped, but host rescue is also stopped.");
            else appendLog("⚠ Warning: the new value could not be read back — check it with RescueParty status.");
        });
    }

    // 5.9.15: device info dump — deliberately root-free (Build
    // fields + a plain shell for uname), so it works even when
    // temp root is not active.
    private void deviceInfoDump() {
        executor.execute(() -> {
            String kernel = "unknown";
            try {
                Process p = new ProcessBuilder("sh", "-c", "uname -r").start();
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line = r.readLine();
                if (line != null && !line.trim().isEmpty()) kernel = line.trim();
                p.waitFor();
            } catch (Exception ignored) {}
            appendLog("--- Device info (no root needed) ---");
            appendLog("Model: " + android.os.Build.MODEL);
            appendLog("Build id: " + android.os.Build.ID);
            appendLog("Android: " + android.os.Build.VERSION.RELEASE + " (SDK " + android.os.Build.VERSION.SDK_INT + ")");
            appendLog("Kernel: " + kernel);
            appendLog("Current slot: " + selectedSlot);
            appendLog("Root status: " + (isRootGranted ? "temp root active" : "no root right now"));
        });
    }

    private void saveAllLogs() {
        saveLogcatAndShow();
        if (!isRootGranted) {
            appendLog("Kernel log skipped — needs temp root. The app + system logs above were still saved.");
            return;
        }
        executor.execute(() -> {
            try {
                List<String> lines = new ArrayList<>();
                runRootCmdCaptured("dmesg 2>/dev/null | tail -500", lines);
                File f = new File(getFilesDir(), "kernel_log.txt");
                try (OutputStream o = new FileOutputStream(f, false)) {
                    for (String l : lines) o.write((l + "\n").getBytes("UTF-8"));
                }
                appendLog("Kernel log saved: " + f.getAbsolutePath() + " (" + lines.size() + " lines)");
            } catch (Exception e) {
                appendLog("Kernel log save failed: " + e.getMessage());
            }
        });
    }

    // 5.9.16: one-tap diagnostics bundle export (Experimental
    // menu). A single file holding: the app operation log, the
    // takeover log (slot + stage), the inner takeover log, the
    // boot_diagnostics bundle, a pstore excerpt, and device info.
    // Root-only sections are included only when temp root is
    // active; without root the bundle still exports the app log +
    // device info and says which sections were skipped. NOTE: the
    // pstore excerpt is read DIRECTLY from /sys/fs/pstore (head
    // -100 per file) and deliberately does NOT run pstore_check.sh
    // — that script is report-once, and exporting must never
    // consume the one verdict the launch sweep would surface.
    private void exportDiagnosticsBundle() {
        executor.execute(() -> {
            try {
                StringBuilder sb = new StringBuilder();
                sb.append("GSI Loader Samsung diagnostics bundle\n");
                sb.append("Exported: ").append(new java.util.Date().toString()).append("\n");
                sb.append("Model: ").append(android.os.Build.MODEL).append("\n");
                sb.append("Build id: ").append(android.os.Build.ID).append("\n");
                sb.append("Android: ").append(android.os.Build.VERSION.RELEASE)
                    .append(" (SDK ").append(android.os.Build.VERSION.SDK_INT).append(")\n");
                sb.append("Current slot: ").append(selectedSlot).append("\n");
                sb.append("Root status: ").append(isRootGranted ? "temp root active" : "no root right now").append("\n");
                try {
                    Process p = new ProcessBuilder("sh", "-c", "uname -r").start();
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line = r.readLine();
                    if (line != null && !line.trim().isEmpty()) sb.append("Kernel: ").append(line.trim()).append("\n");
                    p.waitFor();
                } catch (Exception ignored) {}
                sb.append("\n===== app operation log (operation_log.txt) =====\n");
                try {
                    File opLog = new File(getFilesDir(), "operation_log.txt");
                    if (opLog.exists()) {
                        try (java.io.FileInputStream in = new java.io.FileInputStream(opLog)) {
                            byte[] buf = new byte[32768];
                            int n;
                            while ((n = in.read(buf)) != -1) sb.append(new String(buf, 0, n, "UTF-8"));
                        }
                    } else sb.append("(no operation log yet)\n");
                } catch (Exception e) {
                    sb.append("(app log read failed: ").append(e.getMessage()).append(")\n");
                }
                if (isRootGranted) {
                    String dir = currentSlotDir();
                    String[][] sections = {
                        {"takeover log (slot takeover_app.log, last 300 lines)", "tail -300 \"" + dir + "/takeover_app.log\" 2>/dev/null"},
                        {"takeover log (stage takeover_app.log, last 300 lines)", "tail -300 \"" + STAGE_DIR + "/takeover_app.log\" 2>/dev/null"},
                        {"inner takeover log (data/takeover.log, last 300 lines)", "tail -300 \"" + dir + "/data/takeover.log\" 2>/dev/null"},
                        {"boot diagnostics bundle", "cat \"" + dir + "/boot_diagnostics.log\" 2>/dev/null; cat \"" + STAGE_DIR + "/boot_diagnostics.log\" 2>/dev/null"},
                        {"pstore excerpt (console/dmesg ramoops, head 100 lines each — direct read, NOT pstore_check.sh)", "for f in /sys/fs/pstore/console-ramoops* /sys/fs/pstore/dmesg-ramoops*; do [ -f \"$f\" ] && { echo \"== $f\"; head -100 \"$f\" 2>/dev/null; }; done"},
                    };
                    for (String[] sec : sections) {
                        sb.append("\n===== ").append(sec[0]).append(" =====\n");
                        List<String> lines = new ArrayList<>();
                        runRootCmdCaptured(sec[1], lines);
                        if (lines.isEmpty()) sb.append("(empty / not present)\n");
                        else for (String l : lines) sb.append(l).append("\n");
                    }
                } else {
                    sb.append("\n===== root sections skipped (no temp root) =====\n");
                    sb.append("Takeover log, inner log, boot diagnostics and pstore excerpt need temp root — re-apply temp root and export again for the full bundle.\n");
                }
                File logDir = new File(getExternalFilesDir(null), "logs");
                if (!logDir.exists()) logDir.mkdirs();
                File out = new File(logDir, "diagnostics_bundle_" + System.currentTimeMillis() + ".txt");
                try (OutputStream o = new FileOutputStream(out)) {
                    o.write(sb.toString().getBytes("UTF-8"));
                }
                final String path = out.getAbsolutePath();
                final int bytes = sb.length();
                appendLog("Diagnostics bundle exported: " + path + " (" + bytes + " chars: app log + takeover log + inner log + boot diagnostics + pstore excerpt + device info). Share this file when reporting a failed boot.");
                mainHandler.post(() -> new AlertDialog.Builder(MainActivity.this)
                        .setTitle("Diagnostics bundle exported")
                        .setMessage("Saved to:\n" + path + "\n\nIt holds the app log, takeover log, inner log, boot diagnostics, pstore excerpt and device info in one file — share it when reporting a failed boot.")
                        .setPositiveButton("OK", null).show());
            } catch (Exception e) {
                appendLog("Diagnostics bundle export failed: " + e.getMessage());
            }
        });
    }

    private void showGuideDialog() {
        String g = "HOW TO USE GSI LOADER SAMSUNG\n\n"
            + "WHAT THIS APP DOES\n"
            + "This app runs a second Android system (a GSI) as a guest inside your phone. It uses your phone's own kernel and hardware parts, so it is not a separate virtual machine. Your Samsung system is never replaced and nothing is ever flashed: the guest lives in a folder on this phone, and rebooting the phone always brings Samsung back.\n\n"
            + "INSTALL, THEN BOOT\n"
            + "Two steps, in order. First Install puts a guest system on this phone. Then Boot switches the screen to it. To get back to Samsung, tap Return to One UI — or just reboot the phone, which always boots Samsung, because nothing was flashed. While Boot runs, the log streams the takeover's own progress (modem wait, then steps 1–6) so a minute of real work does not look hung. If the guest takes over the screen but never reaches home, a watchdog returns the phone to One UI automatically after 10 minutes — the guest itself is kept, so you can try again — and the app tells you on next launch.\n\n"
            + "CHOOSING A SYSTEM\n"
            + "LineageOS 23.2 (no Google apps) is the lightweight preset, downloaded from the preset link. LineageOS 23.2 + Google apps adds the Play Store and Play Services. Your own system image accepts any guest system: paste a download link, or pick a file already on this phone. A picked file installs directly — it is not a download.\n\n"
            + "FILESYSTEM\n"
            + "The Filesystem picker above the presets chooses EXT4 or EROFS. EXT4 is the read-write default and comes with the 23.2 presets. EROFS is read-only and faster to read; its presets are the 23.2 release, same as EXT4. Switching filesystem keeps the same flavor (no Google apps / + Google apps). The installer already understands both filesystems, so an EROFS image installs the same way an EXT4 one does.\n\n"
            + "SLOTS\n"
            + "A slot is a separate installed guest system, with its own system image and its own guest data. You can keep several — for example one that works and one you are testing — and switch between them with the slot picker. The Default slot is the original single install. Create slot makes an empty slot you can install into. Delete slot removes the picked slot, its system image and its guest data, permanently. The Default slot cannot be deleted — use Delete guest files for it. Duplicate slot copies the picked slot under a new name. Wipe slot data deletes only the guest's data (apps, accounts, files inside the guest); the system image stays, so the next boot starts fresh setup. Clean slate removes ALL guest state at once — every slot's image and data, stage files, cached downloads, and slot records — so the app starts fresh; it refuses while a guest is running, and after a successful wipe it offers to uninstall the app itself. Your Samsung system is never touched. Nothing here runs while that slot's guest is running. A guest counts as running only when its system is actually mounted or its processes are actually alive — a leftover 'guest running' note from a force-restart does not count: the app clears such stale notes on launch, and Return while already in One UI is a no-op that just clears them. If a guest boot runs for minutes then the phone itself restarts, the app checks the previous boot's kernel log on next launch and reports whether it was a kernel panic (and whether the EROFS driver was involved) or a userspace reboot — paste that verdict back if it happens.\n\n"
            + "COMPATIBILITY PATCHES\n"
            + "These patches were built for LineageOS 23.2's system files. Putting them on a different guest system can break its boot, so they are never applied silently — and they do NOT gate on which preset you picked. They gate on the DETECTED version: the app reads the guest's own build.prop (ro.lineage.version / ro.build.version.release) and only then decides. A 23.2 preset image that was renamed or repacked still counts as 23.2 if its build.prop says so, and a non-23.2 image picked from the 23.2 preset slot does NOT get the patches just because of where it came from — preset origin and detected version usually agree, but they are different mechanisms and can disagree, and detection wins. If the booted guest turns out not to be LineageOS 23.2, the app switches these off and the guest boots with its own files untouched.\n\n"
            + "SNAPSHOTS & BACKUPS\n"
            + "A snapshot saves the picked slot's system image and guest data together, so you can roll back to exactly that state. Refresh lists the picked slot's snapshots and backups. Create snapshot asks for a name, then saves that state. Backup system copies the picked slot's installed image to a single backup file next to it; if a backup already exists you are asked before it is overwritten. Restore backup puts that file back as the installed image.\n\n"
            + "GUEST OPTIONS\n"
            + "Guest root: when on, the guest boots with the phone's own root tool available inside it, so apps inside the guest can use root. Display density: how big text and icons look inside the guest. Default leaves the guest alone; a number (dots per inch) resizes it. Shared folder: a folder both sides can see. Put a file in /sdcard/GSI_Shared on Samsung and the guest sees the same file. Guest root shell runs one shell command inside the running guest and prints the output here.\n\n"
            + "SAFETY & CHECKS\n"
            + "Before any boot, the app can check that Samsung's own system partitions are untouched and read-only. Pre-flight check first confirms Samsung's system partitions are still read-only and no guest is mounted outside its folder, then checks the guest setup. Install, boot, backup and snapshots are blocked at 10% battery or below when the phone is not charging; while charging they proceed with a warning, because a plugged-in phone cannot die mid-install. The battery guard toggle turns this protection off entirely.\n\n"
            + "ONE UI HOME SCREEN SAFETY\n"
            + "Saves a copy of Samsung's home screen layout (icons and widgets) so a guest session or a reboot cannot lose it. Restore puts that copy back. Backup markers show when the last backup was taken.\n\n"
            + "LOG\n"
            + "Every action the app takes is written to the Activity Log in plain words, and the same log is saved on the phone. Save logs writes this log plus the phone's system log to the app's files folder and shows you the exact file paths. Share log sends the log shown above to another app. Note: this shows the Samsung-side log, not a log from inside the guest. Experimental (its own button under the log) holds the fun buttons: kernel log from dmesg, live error log and live kernel log streams, boot diagnostics on demand, panic-record check, guest processes, and RescueParty status. In 5.9.16 it is a themed panel of its own with thirteen tools, adding a takeover-log tail, a full chatty live system log, a RescueParty on/off toggle, a device info dump that works without root, and a one-tap diagnostics bundle export (app log + takeover log + inner log + boot diagnostics + pstore excerpt + device info in a single file). The log follows new lines only while you are already watching the tail — scroll up to read back and it stays put until you scroll back down.\n\n"
            + "WIPE AFTER INSTALL\n"
            + "Ticking 'Wipe guest userdata after install' deletes the slot's guest data right after a good install, so the next boot starts fresh setup. The system image is kept. Installs already wipe before installing (except when resuming a download), so the box mainly guarantees a clean first boot in the resume case. 'Wipe slot data' does the same wipe on demand, per slot.\n\n"
            + "PROGRESS BARS\n"
            + "Every major function has its own colorful progress bar next to its button — Install, Download, Boot, Return, Return + reboot, Inspect, Verify, Backup/Restore, slot operations, Wipe, Clean slate, snapshots, guest shell, pre-flight, home-layout backup/restore, and log saving. A bar appears only while its function runs; the log always records completion. Extracting runs inside Install/Download, so its progress shows on those bars.\n\n"
            + "LOOKS\n"
            + "UI style changes the layout itself: Stage is the big spacious default, Compact packs everything close, Focus shows only Install, Boot, Status and Log (the rest hide behind More tools), and Wide uses large type and big buttons. Color themes and skins change colors only, and work alongside any UI style. Material You follows your wallpaper colors on Android 12+.\n\n"
            + "WHILE THE GUEST RUNS\n"
            + "Samsung's own phone service keeps running in the background so texts keep working. Voice calls do not work inside the guest — the guest has no phone service of its own.\n\n"
            + "SAFETY MODEL\n"
            + "Nothing here flashes your phone or writes host partitions. Everything stages under /data/local/tmp/lineage_stage. If a boot fails, reboot the phone: it always comes back to Samsung.";
        TextView tv = new TextView(this);
        tv.setText(g);
        tv.setTextSize(14);
        tv.setPadding(48, 32, 48, 32);
        ScrollView sv = new ScrollView(this);
        sv.addView(tv);
        new AlertDialog.Builder(this).setTitle("How to use").setView(sv)
            .setPositiveButton("Got it", null).show();
    }

    // ================= 5.9.7 end =================

    // 5.9.10: preset -> download URL / size estimate / display label.
    // 5.9.11: EROFS URLs were re-verified against SourceForge's
    // published 23.2 filenames (HEAD 200 OK, 2026-10-28); never
    // invent one.
    private String presetUrlFor(GsiSource source) {
        switch (source) {
            case LINEAGE_GAPPS: return PRESET_URL_GAPPS;
            case LINEAGE_EROFS_VANILLA: return PRESET_URL_EROFS_VANILLA;
            case LINEAGE_EROFS_GAPPS: return PRESET_URL_EROFS_GAPPS;
            case LINEAGE_VANILLA:
            default: return PRESET_URL_VANILLA;
        }
    }

    private long presetEstFor(GsiSource source) {
        switch (source) {
            case LINEAGE_GAPPS: return ESTIMATED_GAPPS_BYTES;
            case LINEAGE_EROFS_VANILLA: return ESTIMATED_EROFS_VANILLA_BYTES;
            case LINEAGE_EROFS_GAPPS: return ESTIMATED_EROFS_GAPPS_BYTES;
            case LINEAGE_VANILLA:
            default: return ESTIMATED_VANILLA_BYTES;
        }
    }

    private String presetLabelFor(GsiSource source) {
        switch (source) {
            case LINEAGE_GAPPS: return "LineageOS 23.2 (GAPPS)";
            case LINEAGE_EROFS_VANILLA: return "LineageOS 23.2 EROFS (VANILLA)";
            case LINEAGE_EROFS_GAPPS: return "LineageOS 23.2 EROFS (GAPPS)";
            case LINEAGE_VANILLA:
            default: return "LineageOS 23.2 (VANILLA)";
        }
    }

    private void installGsi() {
        corruptDownloadRetried = false;
        long nowTap = System.currentTimeMillis();
        // 5.9.16: the debounce used to swallow taps SILENTLY — including
        // the battery-guard Override retry when the user tapped Override
        // within 500 ms of the Install tap (dialog gone, override saved,
        // install never run, no log line). A swallowed tap now logs.
        if (nowTap - lastInstallTapMs < 500) {
            appendLog("Install tap ignored (double-tap guard) — tap Install again.");
            return;
        }
        lastInstallTapMs = nowTap;
        if (pickerCopying) {
            appendLog("Still copying the picked file — Install unlocks the moment the copy lands.");
            return;
        }
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to install a GSI!");
            return;
        }
        // 5.9.17: one install at a time, checked here for instant
        // feedback and again at task start (see installLocalGsi /
        // startNetworkDownload) for the queued-task race. Without
        // this, taps during a running install queued duplicate
        // wipe + install jobs and gave no visible feedback.
        if (installBusy.get()) {
            appendLog("Install already running — wait for it to finish (see the progress text). Tapping again will not queue another install.");
            return;
        }
        // 5.9.5-APP-START
        if (!batteryGuardAllows("install", () -> installGsi())) return;
        // 5.9.5-APP-END
        // 5.9.11: engine gate (see extractAssets) + instant tap
        // feedback: this log line runs on the tap itself, not queued
        // behind any running executor task.
        if (!assetsReady) {
            appendLog("Engine still unpacking — tap Install again in a second.");
            // 5.9.16: extractAssets() no-ops while an unpack is already
            // running, so if this line repeats, the unpack task itself is
            // still queued/running on the executor — say so instead of
            // implying one more tap will fix it.
            if (assetsExtracting) appendLog("Engine unpack task is still queued/running (a background task ahead of it may be holding the queue).");
            extractAssets();
            return;
        }
        appendLog("Install tapped — preparing…");
        saveGsiPrefs();
        if (selectedSource == GsiSource.CUSTOM) {
            String loc = customLocation;
            if (loc == null || loc.isEmpty()) {
                appendLog("ERROR: Custom GSI selected but no URL or local path entered.");
                return;
            }
            if (!loc.startsWith("http://") && !loc.startsWith("https://")) {
                // 5.9.17: the picked cache file used to be deleted
                // after a good install while this field still pointed
                // at it, so every later tap failed instantly with
                // LOCAL_FILE_MISSING — invisible in the frozen log.
                // Refuse loudly here instead of queueing a ghost
                // task, and clear the stale path so the UI stops
                // pointing at a deleted file.
                if (!new File(loc).exists()) {
                    appendLog("ERROR: That GSI file is gone — it was deleted or the cache was cleared (" + loc + "). Pick the file again, then tap Install.");
                    if (etCustomLocation != null) etCustomLocation.setText("");
                    customLocation = "";
                    saveGsiPrefs();
                    return;
                }
                installLocalGsi(loc);
                return;
            }
            startNetworkDownload(loc, -1, "Custom GSI");
        } else {
            // 5.9.10: four presets now (EXT4 + EROFS, each in two
            // flavors). The helpers below map source -> URL/estimate/
            // label; unknown sources fall back to VANILLA, as the old
            // ternary's else branch did.
            startNetworkDownload(presetUrlFor(selectedSource), presetEstFor(selectedSource), presetLabelFor(selectedSource));
        }
    }

    // 5.9.10: read-only image report. Inspects the Custom location
    // when it is a local file, otherwise the cached preset download
    // (gsi_dl.7z in the app cache) when one exists; anything else
    // logs guidance instead of guessing. Runs assets/inspect_image.sh
    // through the same streamed root runner as installs, so its output
    // lands in the Activity Log. It never writes, deletes, installs or
    // boots — it only reads the one file it is pointed at.
    private void inspectGsi() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to inspect an image.");
            return;
        }
        if (etCustomLocation != null) {
            customLocation = etCustomLocation.getText().toString().trim();
        }
        String target = null;
        if (selectedSource == GsiSource.CUSTOM && customLocation != null && !customLocation.isEmpty()
                && !customLocation.startsWith("http://") && !customLocation.startsWith("https://")) {
            target = customLocation;
        } else {
            File cached = new File(getCacheDir(), "gsi_dl.7z");
            if (cached.exists()) target = cached.getAbsolutePath();
        }
        if (target == null) {
            appendLog("Inspect: nothing to inspect — pick a local file (Your own system image) or download a preset first.");
            return;
        }
        appendLog("Inspecting " + target + " …");
        // 5.9.11: was synchronous on the tap thread (main thread) —
        // a big archive listing froze the UI. Now on executor + bar.
        final String fTarget = target;
        runBarTask(pbInspect, tvInspectProgress, "Inspecting image…", () -> {
            List<String> out = new ArrayList<>();
            int rc = runRootCmdStreamed("sh " + STAGE_DIR + "/inspect_image.sh \"" + fTarget + "\" " + STAGE_DIR + "/7zz", out, true);
            if (rc != 0) appendLog("Inspect finished with code " + rc + " (see the lines above).");
            else appendLog("Inspect done.");
            // 5.9.16: pre-install fit report for this candidate
            // (see detectCandidateFit). Archives cannot be version
            // -read before extraction — for those, the install
            // script's own FIT_WARNING covers the same check during
            // install, before install completes.
            detectCandidateFit(fTarget);
        });
    }

    // 5.9.16: pre-install "will it fit + will it boot" report for
    // an install candidate (extends detectFrameworkVersion to the
    // candidate). Called from Inspect (a pre-install check, not
    // the install path itself). The candidate image is loop-mounted
    // read-only to a temp mount under the current slot dir, its
    // build.prop SDK/release read with keyed greps, then unmounted
    // in the same command — the mount is always released, even when
    // the greps find nothing, because umount runs before the shell
    // returns. A guest SDK older than the host vendor SDK (this
    // phone's Build.VERSION.SDK_INT) logs the plain warning "this
    // guest is older than your vendor; expect HAL trouble" BEFORE
    // any install or boot is waited through. Archives and sparse
    // images cannot be mounted directly, so they report
    // FIT_CHECK_SKIPPED honestly: for archives the install script
    // runs the same comparison after extraction (FIT_WARNING,
    // before install completes), and sparse images are converted
    // first by that same script. Free space is NOT re-checked here
    // — install_image.sh already checks candidate + 10% headroom,
    // and duplicating that check would only drift from it.
    // Runs synchronously on the caller's executor task (Inspect's
    // bar task); it never touches the install flow itself.
    private void detectCandidateFit(String target) {
        if (target == null || target.isEmpty()) return;
        String lower = target.toLowerCase();
        if (lower.endsWith(".7z") || lower.endsWith(".zip") || lower.endsWith(".xz")
                || lower.endsWith(".gz") || lower.endsWith(".tgz") || lower.endsWith(".tar")
                || lower.endsWith(".zst") || lower.endsWith(".zstd") || lower.endsWith(".lz4")
                || lower.endsWith(".br")) {
            appendLog("Fit check skipped: an archive's version cannot be read before extraction — the install script will print FIT_WARNING during install if this guest is older than your vendor.");
            return;
        }
        List<String> out = new ArrayList<>();
        runRootCmdCaptured("MNT=" + currentSlotDir() + "/.fitcheck_mnt; mkdir -p \"$MNT\" 2>/dev/null; "
                + "if mount -o ro,loop \"" + target + "\" \"$MNT\" 2>/dev/null || mount -t ext4 -o ro,loop \"" + target + "\" \"$MNT\" 2>/dev/null || mount -t erofs -o ro,loop \"" + target + "\" \"$MNT\" 2>/dev/null; then "
                + "SDK=$(grep -m1 '^ro.build.version.sdk=' \"$MNT/system/build.prop\" 2>/dev/null | cut -d= -f2-); echo \"FIT_SDK:$SDK\"; "
                + "REL=$(grep -m1 '^ro.build.version.release=' \"$MNT/system/build.prop\" 2>/dev/null | cut -d= -f2-); echo \"FIT_REL:$REL\"; "
                + "umount \"$MNT\" 2>/dev/null; else echo \"FIT_NOMOUNT\"; fi; rmdir \"$MNT\" 2>/dev/null; true", out);
        String sdk = null, rel = null;
        boolean noMount = false;
        for (String line : out) {
            String t = line.trim();
            if (t.startsWith("FIT_SDK:")) sdk = t.substring(8);
            else if (t.startsWith("FIT_REL:")) rel = t.substring(8);
            else if ("FIT_NOMOUNT".equals(t)) noMount = true;
        }
        if (noMount || sdk == null || sdk.isEmpty()) {
            appendLog("Fit check skipped: candidate image could not be loop-mounted read-only for a build.prop read (sparse images are converted during install, where the install script runs this same check — see FIT_WARNING there).");
            return;
        }
        try {
            int guestSdk = Integer.parseInt(sdk.trim());
            int hostSdk = android.os.Build.VERSION.SDK_INT;
            if (guestSdk < hostSdk) {
                appendLog("⚠ Fit warning: this guest is older than your vendor (guest Android " + (rel != null ? rel : "?") + " SDK " + guestSdk + " vs host SDK " + hostSdk + ") — expect HAL trouble. Install it anyway only if you accept broken radio/camera/audio risk.");
            } else {
                appendLog("Fit OK: guest SDK " + guestSdk + " vs host SDK " + hostSdk + " (guest is not older than your vendor).");
            }
        } catch (Exception ignored) {
            appendLog("Fit check skipped: guest SDK value '" + sdk + "' is not a number.");
        }
    }

    // Opens the system file picker so the user can SELECT a GSI file
    // (archive or raw image) instead of typing a path. The picked content
    // is copied to a real file path because the root install commands
    // below need a filesystem path, not a content:// URI.
    private void launchGsiPicker() {
        try {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("*/*");
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivityForResult(intent, REQ_PICK_GSI);
        } catch (Exception e) {
            appendLog("ERROR: No file picker available on this device.");
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        // 5.9.16: a picker return that is NOT RESULT_OK with data used to
        // fall through with no log at all — the user had picked nothing
        // (or the provider returned nothing) and Install still pointed
        // at the previous source, which reads as "Install does nothing".
        if (requestCode == REQ_PICK_GSI && !(resultCode == RESULT_OK && data != null && data.getData() != null)) {
            appendLog("File picker closed without a file — nothing changed. Pick a file, then tap Install.");
            return;
        }
        if (requestCode == REQ_PICK_GSI && resultCode == RESULT_OK && data != null && data.getData() != null) {
            final Uri uri = data.getData();
            // 5.9.7: Install is disabled until the copy post completes, so
            // a tap during the copy can never run against the stale source.
            pickerCopying = true;
            refreshInstallEnabled();
            // 5.9.16: a multi-GB copy used to run with zero feedback —
            // no log, no bar — while Install sat disabled-but-identical.
            // Log the copy start so the wait is visible, not dead.
            appendLog("Copying picked file… (Install unlocks when the copy lands.)");
            // 5.9.16: runs on pickerExecutor, not the root-op executor
            // (see its declaration) — a queued download/install can no
            // longer starve this copy and strand Install disabled.
            pickerExecutor.execute(() -> {
                try {
                    String name = queryDisplayName(uri);
                    if (name == null || name.isEmpty()) name = "picked_gsi";
                    // Root install commands need a path with no spaces.
                    name = name.replaceAll("\\s+", "_");
                    File dir = new File(getCacheDir(), "gsi_pick");
                    if (!dir.exists()) dir.mkdirs();
                    File dest = new File(dir, name);
                    try (InputStream in = getContentResolver().openInputStream(uri);
                         OutputStream out = new FileOutputStream(dest)) {
                        if (in == null) throw new Exception("Could not open picked file.");
                        byte[] buf = new byte[65536];
                        int n;
                        // 5.9.16: progress for slow providers (cloud
                        // pickers stream over the network): a line every
                        // 512 MB so a long copy never looks like a hang.
                        long copied = 0, nextMark = 512L * 1048576L;
                        while ((n = in.read(buf)) != -1) {
                            out.write(buf, 0, n);
                            copied += n;
                            if (copied >= nextMark) {
                                final long mb = copied / 1048576L;
                                appendLog("Copying picked file… " + mb + " MB so far.");
                                nextMark += 512L * 1048576L;
                            }
                        }
                    }
                    final String path = dest.getAbsolutePath();
                    mainHandler.post(() -> {
                        if (etCustomLocation != null) etCustomLocation.setText(path);
                        saveGsiPrefs();
                        // 5.9.6 FIX (the user's exact complaint): picking a
                        // local file now MAKES it the selected source, so
                        // Install uses the picked file directly. Before,
                        // the source stayed on whatever preset was picked
                        // and Install would download that preset instead,
                        // leaving the user to hunt for the right button.
                        selectSource(GsiSource.CUSTOM, true);
                        if (etCustomLocation != null) etCustomLocation.setText(path);
                        saveGsiPrefs();
                        pickerCopying = false;
                        refreshInstallEnabled();
                        appendLog("Picked GSI file: " + path + " — tap Install to install it directly (it is not a download).");
                    });
                } catch (Exception e) {
                    mainHandler.post(() -> { pickerCopying = false; refreshInstallEnabled(); appendLog("ERROR: Could not copy picked GSI file: " + e.getMessage()); });
                }
            });
        }
    }

    private String queryDisplayName(Uri uri) {
        try (Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) return c.getString(idx);
            }
        } catch (Exception ignored) {}
        String last = uri.getLastPathSegment();
        return last != null ? last : null;
    }

    // Turns a picked/downloaded GSI file into the SELECTED SLOT's system.raw
    // (Default slot: STAGE_DIR/system.raw — the original behaviour).
    // The real logic lives in assets/install_image.sh (synced to STAGE_DIR
    // by extractAssets): recursive system.img search, super/sparse rejects,
    // ext4/EROFS detection, free-space check, atomic rename. moveInput=true
    // (downloads) may consume the input when it IS the image; false (user
    // local files) never deletes the user's file.
    // 5.9.16: single-quote a path for a `su -c` command line (embedded
    // quotes escaped the POSIX way). The local path used to be spliced
    // in UNQUOTED, so a picked/typed filename with shell metacharacters
    // — e.g. a re-download named `gsi (1).img` (the picker strips spaces
    // but not parens) — made the whole root command fail to parse and
    // the install died before install_image.sh ever ran. Quoting here
    // covers every installImageCmd caller; install_image.sh itself
    // already quotes its $1..$4 internally.
    private String shQuote(String p) {
        if (p == null) return "''";
        return "'" + p.replace("'", "'\\''") + "'";
    }

    private String installImageCmd(String inputPath, boolean moveInput) {
        return installImageCmd(inputPath, moveInput, currentSlotDir(), currentSystemRaw());
    }

    private String installImageCmd(String inputPath, boolean moveInput, String slotDir, String systemRaw) {
        return shQuote(slotDir + "/install_image.sh") + " " + shQuote(inputPath) + " " + (moveInput ? "1" : "0") + " " + shQuote(slotDir) + " " + shQuote(systemRaw);
    }

    // Read-only check of the installed system.raw: reports its size and
    // detected format (ext4 / EROFS / sparse / super / unknown) to the log.
    // Never mounts or modifies anything.
    // Safestrap-style safety net, userspace edition: the installed GSI lives
    // only in /data staging, so a backup is just a copy of system.raw.
    // Backing up is always safe (the loop mount is read-only). Restoring
    // while the guest is running is refused: overwriting system.raw under
    // a live loop mount would corrupt the running guest.
    private void backupGsi() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to back up a GSI!");
            return;
        }
        // 5.9.5-APP-START
        if (!batteryGuardAllows("backup", () -> backupGsi())) return;
        // 5.9.5-APP-END
        // 5.9.6: the single backup overwrites any previous one — ask
        // first when one already exists, instead of silently destroying
        // the only copy of an earlier system.
        executor.execute(() -> {
            boolean bakExists = runRootCmdDrained("[ -f " + currentSystemRaw() + ".bak ]") == 0;
            if (!bakExists) { doBackupGsi(); return; }
            mainHandler.post(() -> new AlertDialog.Builder(MainActivity.this)
                .setTitle("Replace the existing backup?")
                .setMessage("Slot '" + selectedSlot + "' already has a backup file. Backing up again replaces it — the earlier backed-up system will be gone. To keep both, use Create multi-gen backup instead (it never overwrites).")
                .setPositiveButton("Replace", (dialog, which) -> doBackupGsi())
                .setNegativeButton("Cancel", null)
                .show());
        });
    }

    private void doBackupGsi() {
        // 5.9.11: own colorful bar (Backup/Restore share one bar).
        runBarTask(pbBackup, tvBackupProgress, "Backing up system…", () -> {
            try {
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "if [ ! -f " + currentSystemRaw() + " ]; then echo 'BACKUP: no system.raw installed (slot " + selectedSlot + ")'; exit 0; fi; "
                    + "SZ=$(stat -c %s " + currentSystemRaw() + " 2>/dev/null || echo 0); "
                    // 5.9.11: MB via awk doubles, not shell arithmetic —
                    // $((SZ/1048576)) wraps negative for >2 GiB images
                    // (same overflow class as the 5.9.10 install fix).
                    // Display-only; backup never gates anything.
                    + "MB=$(echo $SZ | awk '{print int($1/1048576)}'); "
                    + "cp -f " + currentSystemRaw() + " " + currentSystemRaw() + ".bak && chmod 644 " + currentSystemRaw() + ".bak && "
                    + "[ $(stat -c %s " + currentSystemRaw() + ".bak 2>/dev/null || echo 0) = $SZ ] && "
                    + "echo 'BACKUP: OK ' $MB ' MB -> [' + selectedSlot + '] system.raw.bak' || echo 'BACKUP: FAILED'"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                while ((line = r.readLine()) != null) appendLog(line);
                p.waitFor();
            } catch (Exception e) {
                appendLog("Backup failed: " + e.getMessage());
            }
        });
    }

    private void confirmRestoreGsi() {
        new AlertDialog.Builder(this)
            .setTitle("Restore GSI backup?")
            .setMessage("This replaces the installed system.raw with system.raw.bak. The guest must not be running (return to One UI first). The backup itself is kept, so you can restore again.")
            .setPositiveButton("Restore", (dialog, which) -> restoreGsi())
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void restoreGsi() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to restore a GSI!");
            return;
        }
        // 5.9.11: own colorful bar (Backup/Restore share one bar).
        runBarTask(pbBackup, tvBackupProgress, "Restoring backup…", () -> {
            try {
            // 5.9.5-INT-START: guard before restoring a backup.
            if (slotGuardRunning(currentSlotDir())) {
                appendLog("Restore refused: slot '" + selectedSlot + "' guest is running — return to One UI first.");
                return;
            }
            // 5.9.5-INT-END
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "if [ ! -f " + currentSystemRaw() + ".bak ]; then echo 'RESTORE: no backup found (slot " + selectedSlot + " - back up first)'; exit 0; fi; "
                    + "if mount | grep -q '" + currentRootfs() + " '; then echo 'RESTORE: guest is running — return to One UI first'; exit 0; fi; "
                    + "SZ=$(stat -c %s " + currentSystemRaw() + ".bak 2>/dev/null || echo 0); "
                    // 5.9.11: MB via awk doubles (same >2 GiB overflow
                    // class as the backup/verify fixes; display-only).
                    + "MB=$(echo $SZ | awk '{print int($1/1048576)}'); "
                    + "cp -f " + currentSystemRaw() + ".bak " + currentSystemRaw() + ".new && "
                    + "[ $(stat -c %s " + currentSystemRaw() + ".new 2>/dev/null || echo 0) = $SZ ] && "
                    + "mv -f " + currentSystemRaw() + ".new " + currentSystemRaw() + " && chmod 644 " + currentSystemRaw() + " && "
                    + "echo 'RESTORE: OK ' $MB ' MB' || echo 'RESTORE: FAILED'"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                while ((line = r.readLine()) != null) appendLog(line);
                p.waitFor();
                checkImageStatus();
            } catch (Exception e) {
                appendLog("Restore failed: " + e.getMessage());
            }
        });
    }

    // --- GSI slots (5.9.3, userspace recovery) ---
    // The slot list is derived from the filesystem (Default + STAGE/slots/*),
    // so it survives reinstalls and can never disagree with what is on disk.
    // The selected slot is persisted in prefs; a missing selection falls
    // back to Default.
    private void refreshSlots() {
        executor.execute(() -> {
            List<String> names = new ArrayList<>();
            names.add(DEFAULT_SLOT);
            if (isRootGranted) {
                try {
                    Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                        "ls -d " + STAGE_DIR + "/slots/*/ 2>/dev/null"});
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line;
                    while ((line = r.readLine()) != null) {
                        line = line.trim();
                        if (line.endsWith("/")) line = line.substring(0, line.length() - 1);
                        int slash = line.lastIndexOf('/');
                        String n = slash >= 0 ? line.substring(slash + 1) : line;
                        if (isValidSlotName(n) && !names.contains(n)) names.add(n);
                    }
                    p.waitFor();
                } catch (Exception ignored) {}
            }
            if (names.size() > 1) Collections.sort(names.subList(1, names.size()));
            // 5.9.6: mark which slots actually have a system installed, so
            // picking a slot to boot is not a guessing game. Only when
            // root is available (otherwise presence is unknown, and no
            // suffix is shown rather than a wrong one).
            final java.util.Set<String> installed = new java.util.HashSet<>();
            if (isRootGranted) {
                try {
                    StringBuilder chk = new StringBuilder();
                    for (String n : names) {
                        String d = n.equals(DEFAULT_SLOT) ? STAGE_DIR : STAGE_DIR + "/slots/" + n;
                        chk.append("[ -f ").append(d).append("/system.raw ] && echo HAS:").append(n).append("; ");
                    }
                    Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", chk.toString()});
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line;
                    while ((line = r.readLine()) != null) {
                        line = line.trim();
                        if (line.startsWith("HAS:")) installed.add(line.substring(4));
                    }
                    p.waitFor();
                } catch (Exception ignored) {}
            }
            final List<String> slotNames = names;
            mainHandler.post(() -> {
                if (spSlot == null) return;
                if (!slotNames.contains(selectedSlot)) { selectedSlot = DEFAULT_SLOT; saveGsiPrefs(); }
                slotValues = new ArrayList<>(slotNames);
                List<String> labels = new ArrayList<>();
                for (String n : slotNames) {
                    String base = n.equals(DEFAULT_SLOT) ? "Default (original install)" : n;
                    // 5.9.16: per-slot last-boot outcome in the picker
                    // label itself (short form), so a slot that last
                    // watchdog-timed-out or panicked is visible before
                    // it is picked, not only on its detail card.
                    String outcomeSuffix = "";
                    try {
                        String stored = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_LAST_BOOT_OUTCOME_PREFIX + n, null);
                        String shortOutcome = lastBootOutcomeShort(stored);
                        if (shortOutcome != null) outcomeSuffix = " • last: " + shortOutcome;
                    } catch (Exception ignored) {}
                    if (isRootGranted) labels.add((installed.contains(n) ? base + " ✓ installed" : base + " (empty)") + outcomeSuffix);
                    else labels.add(base + outcomeSuffix);
                }
                ArrayAdapter<String> ad = new ArrayAdapter<>(MainActivity.this,
                        R.layout.spinner_item, labels);
                ad.setDropDownViewResource(R.layout.spinner_dropdown_item);
                slotSpinnerInit = false;
                spSlot.setAdapter(ad);
                int pos = slotNames.indexOf(selectedSlot);
                spSlot.setSelection(pos < 0 ? 0 : pos, false);
                slotSpinnerInit = true;
                // 5.9.5-APP-START
                refreshBootMenuInfo(null, null, null);
                // 5.9.5-APP-END
            });
        });
    }

    private interface SlotNameAction { void run(String name); }

    private void promptSlotName(String title, SlotNameAction action) {
        final EditText input = new EditText(this);
        input.setHint("letters, digits, -, _ (max 32)");
        new AlertDialog.Builder(this)
            .setTitle(title)
            .setView(input)
            .setPositiveButton("OK", (dialog, which) -> {
                String name = input.getText().toString().trim();
                action.run(name);
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void createSlot() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to create a slot!");
            return;
        }
        promptSlotName("Create GSI slot", name -> {
            if (name.equals(DEFAULT_SLOT)) {
                appendLog("ERROR: 'Default' is the reserved name of the original install.");
                return;
            }
            if (!isValidSlotName(name)) {
                appendLog("ERROR: Invalid slot name '" + name + "'. Use 1-32 chars: letters, digits, -, _.");
                return;
            }
            // 5.9.11: own colorful bar (slot ops share one bar).
            runBarTask(pbSlot, tvSlotProgress, "Creating slot…", () -> {
                int ret = runRootCmdDrained("mkdir -p " + STAGE_DIR + "/slots/" + name
                        + " && chmod 777 " + STAGE_DIR + "/slots/" + name);
                if (ret == 0) {
                    appendLog("Slot created: " + name + " — install a GSI into it, then boot it.");
                    selectedSlot = name;
                    saveGsiPrefs();
                    refreshSlots();
                    checkImageStatus();
                } else {
                    appendLog("ERROR: Could not create slot '" + name + "' (exit " + ret + ").");
                }
            });
        });
    }

    private void deleteSlot() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to delete a slot!");
            return;
        }
        if (isDefaultSlot()) {
            appendLog("The Default slot cannot be deleted — use 'Delete guest files' to remove its system image and guest data. (Default is the original single install.)");
            return;
        }
        final String slot = selectedSlot;
        final String dir = slotDir(slot);
        new AlertDialog.Builder(this)
            .setTitle("Delete slot '" + slot + "'?")
            .setMessage("DELETE removes everything in this slot: its system image, its backup, its guest data, its snapshots and its backups — and the slot itself is gone. This cannot be undone. To keep the system image and only clear the guest's data, use Wipe slot data instead. The guest must not be running.")
            .setPositiveButton("Delete", (dialog, which) -> runBarTask(pbSlot, tvSlotProgress, "Deleting slot…", () -> {
                try {
                // 5.9.5-INT-START: guard before deleting a slot.
                if (slotGuardRunning(dir)) {
                    appendLog("Delete refused: slot '" + slot + "' guest is running — return to One UI first.");
                    return;
                }
                // 5.9.5-INT-END
                // 5.9.6 FIX (on-device 5.9.5 bug: first delete failed with a
                // bare "Could not delete", then later attempts confusingly
                // succeeded): stale mounts under the slot dir (loop mounts
                // and bind mounts left by an earlier guest session) made
                // rm -rf fail while the code reported nothing specific.
                // Unmount the slot's mounts first, then remove, then
                // VERIFY the dir is actually gone and say exactly what
                // is left if it is not — one clear outcome per tap.
                String unmount = containerUnmountCmd(dir);
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    unmount + "; "
                    + "if mount | grep -q '" + dir + "/rootfs '; then echo 'SLOT_RUNNING'; "
                    + "elif rm -rf " + dir + " && [ ! -e " + dir + " ]; then echo 'SLOT_DELETED'; "
                    + "else echo 'SLOT_DELETE_FAILED'; ls -A " + dir + " 2>/dev/null | head -5; fi"});
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line;
                    boolean deleted = false, running = false, failed = false;
                    StringBuilder leftover = new StringBuilder();
                    while ((line = r.readLine()) != null) {
                        if (line.contains("SLOT_DELETED")) deleted = true;
                        else if (line.contains("SLOT_RUNNING")) running = true;
                        else if (line.contains("SLOT_DELETE_FAILED")) failed = true;
                        else if (failed && leftover.length() < 200) leftover.append(line).append(" ");
                    }
                    p.waitFor();
                    if (running) {
                        appendLog("Delete refused: slot '" + slot + "' guest is running — return to One UI first.");
                    } else if (deleted) {
                        appendLog("Slot deleted: " + slot + " (system image, backup, guest data, snapshots and backups removed).");
                        try {
                            android.content.SharedPreferences.Editor e = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
                                .remove(PREF_NOTE_PREFIX + slot).remove(PREF_BOOTS_PREFIX + slot).remove(PREF_SHA_PREFIX + slot)
                                .remove(PREF_DENSITY_PREFIX + slot).remove(PREF_SHARE_PREFIX + slot)
                                .remove(PREF_GUEST_ROOT_PREFIX + slot).remove(PREF_COLOR_PREFIX + slot)
                                // 5.9.16: the deleted slot's last-boot
                                // outcome goes with it (a duplicated
                                // slot likewise never inherits one —
                                // it has never booted).
                                .remove(PREF_LAST_BOOT_OUTCOME_PREFIX + slot);
                            String last = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_LAST_BOOT, null);
                            if (slot.equals(last)) e.remove(PREF_LAST_BOOT);
                            e.apply();
                        } catch (Exception ignored) {}
                        selectedSlot = DEFAULT_SLOT;
                        saveGsiPrefs();
                        refreshSlots();
                        checkImageStatus();
                    } else {
                        appendLog("Delete FAILED for slot '" + slot + "': the slot folder could not be fully removed"
                                + (leftover.length() > 0 ? " (still there: " + leftover.toString().trim() + ")" : "")
                                + ". A stale mount or busy file is the usual cause — reboot the phone and try again.");
                    }
                } catch (Exception e) {
                    appendLog("Delete slot failed: " + e.getMessage());
                }
            }))
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void duplicateSlot() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to duplicate a slot!");
            return;
        }
        final String src = selectedSlot;
        final String srcDir = currentSlotDir();
        promptSlotName("Duplicate slot '" + src + "' as", name -> {
            if (name.equals(DEFAULT_SLOT)) {
                appendLog("ERROR: 'Default' is the reserved name of the original install.");
                return;
            }
            if (!isValidSlotName(name)) {
                appendLog("ERROR: Invalid slot name '" + name + "'. Use 1-32 chars: letters, digits, -, _.");
                return;
            }
            final String dstDir = STAGE_DIR + "/slots/" + name;
            // 5.9.11: own colorful bar (slot ops share one bar).
            runBarTask(pbSlot, tvSlotProgress, "Duplicating slot…", () -> {
                try {
                    // 5.9.6 FIX: duplicating the Default slot used to run
                    // cp -a STAGE_DIR STAGE_DIR/slots/<name> — a directory
                    // copied into its own subdirectory, which cp refuses
                    // (or mangles). Copy the Default slot's CONTENTS
                    // instead, excluding the slots/ subtree itself and the
                    // stale .guest_running marker. Named slots copy as a
                    // whole (no self-containment there).
                    String copyCmd;
                    if (src.equals(DEFAULT_SLOT)) {
                        copyCmd = "mkdir -p " + dstDir + " && cd " + STAGE_DIR + " && find . -mindepth 1 -maxdepth 1 ! -name slots ! -name .guest_running -exec cp -a {} " + dstDir + "/ \\; && chmod 777 " + dstDir + " && echo 'SLOT_COPIED'";
                    } else {
                        copyCmd = "cp -a " + srcDir + " " + dstDir + " && chmod 777 " + dstDir + " && echo 'SLOT_COPIED'";
                    }
                    Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                        "if mount | grep -q '" + srcDir + "/rootfs '; then echo 'SLOT_RUNNING'; "
                        + "elif [ -e " + dstDir + " ]; then echo 'SLOT_EXISTS'; "
                        + "else " + copyCmd + "; fi"});
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line;
                    boolean copied = false, running = false, exists = false;
                    while ((line = r.readLine()) != null) {
                        if (line.contains("SLOT_COPIED")) copied = true;
                        if (line.contains("SLOT_RUNNING")) running = true;
                        if (line.contains("SLOT_EXISTS")) exists = true;
                    }
                    p.waitFor();
                    if (running) {
                        appendLog("Duplicate refused: slot '" + src + "' guest is running — return to One UI first (a live guest's data would copy inconsistently).");
                    } else if (exists) {
                        appendLog("ERROR: Slot '" + name + "' already exists.");
                    } else if (copied) {
                        appendLog("Slot duplicated: " + src + " -> " + name + " (system image, guest data and settings copied).");
                        try {
                            // 5.9.6: a duplicate used to lose the slot's
                            // settings (density, shared folder, guest root,
                            // color) — only the note was copied. Copy them
                            // all so the new slot behaves like the old one.
                            android.content.SharedPreferences pr = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
                            android.content.SharedPreferences.Editor e = pr.edit();
                            String n = pr.getString(PREF_NOTE_PREFIX + src, null);
                            if (n != null && !n.isEmpty()) e.putString(PREF_NOTE_PREFIX + name, n);
                            String d = pr.getString(PREF_DENSITY_PREFIX + src, null);
                            if (d != null && !d.isEmpty()) e.putString(PREF_DENSITY_PREFIX + name, d);
                            if (pr.contains(PREF_SHARE_PREFIX + src)) e.putBoolean(PREF_SHARE_PREFIX + name, pr.getBoolean(PREF_SHARE_PREFIX + src, false));
                            if (pr.contains(PREF_GUEST_ROOT_PREFIX + src)) e.putBoolean(PREF_GUEST_ROOT_PREFIX + name, pr.getBoolean(PREF_GUEST_ROOT_PREFIX + src, false));
                            if (pr.contains(PREF_COLOR_PREFIX + src)) e.putInt(PREF_COLOR_PREFIX + name, pr.getInt(PREF_COLOR_PREFIX + src, 0xFF888888));
                            e.apply();
                        } catch (Exception ignored) {}
                        selectedSlot = name;
                        saveGsiPrefs();
                        refreshSlots();
                        checkImageStatus();
                    } else {
                        appendLog("ERROR: Could not duplicate slot '" + src + "'.");
                    }
                } catch (Exception e) {
                    appendLog("Duplicate slot failed: " + e.getMessage());
                }
            });
        });
    }

    private void confirmWipeSlot() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to wipe slot data!");
            return;
        }
        final String slot = selectedSlot;
        new AlertDialog.Builder(this)
            .setTitle("Wipe guest data for slot '" + slot + "'?")
            .setMessage("This deletes the slot's guest /data only — its system.raw is kept. This cannot be undone. The guest must not be running.")
            .setPositiveButton("Wipe", (dialog, which) -> wipeSlot())
            .setNegativeButton("Cancel", null)
            .show();
    }

    // 5.9.5-INT-START: destructive-op guard (check_slot_guard.sh + mount fallback).
    private boolean slotGuardRunning(String dir) {
        try {
            String script = new File(getFilesDir(), "check_slot_guard.sh").getAbsolutePath();
            Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                "if [ -x \"" + script + "\" ]; then sh \"" + script + "\" \"" + dir + "\"; else echo GUARD_NOSCRIPT; fi"});
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line; boolean sawOk = false, sawRunning = false;
            while ((line = r.readLine()) != null) {
                if (line.contains("GUARD_RUNNING")) sawRunning = true;
                if (line.contains("GUARD_OK")) sawOk = true;
            }
            p.waitFor();
            if (sawRunning) return true;
            if (sawOk) return false;
            Process q = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                "if mount | grep -q '" + dir + "/rootfs '; then echo GUARD_RUNNING; else echo GUARD_OK; fi"});
            BufferedReader r2 = new BufferedReader(new InputStreamReader(q.getInputStream()));
            String l2; boolean run2 = false;
            while ((l2 = r2.readLine()) != null) { if (l2.contains("GUARD_RUNNING")) run2 = true; }
            q.waitFor();
            return run2;
        } catch (Exception e) {
            // 5.9.16: FAIL-CLOSED. The old code returned false here,
            // so a guard check that itself threw (su died, script
            // unreadable, process spawn failed) let the guarded
            // operation PROCEED against an unknown guest state — a
            // fail-open guard hole. Now a throwing guard REFUSES
            // loudly: the app log + status say so, and every caller
            // treats "true" as "guest running" and refuses its
            // operation. A false refusal costs one retry; a false
            // pass can wipe a running guest's data.
            appendLog("Guard check FAILED for '" + dir + "' (" + e.getMessage() + ") — refusing the operation rather than proceeding blind. Re-apply temp root and retry.");
            setLogStatus("Error");
            return true;
        }
    }
    // 5.9.5-INT-END

    private void wipeSlot() {
        final String slot = selectedSlot;
        final String dir = currentSlotDir();
        // 5.9.11: own colorful bar.
        runBarTask(pbWipe, tvWipeProgress, "Wiping slot data…", () -> {
            try {
            // 5.9.5-INT-START: guard before wiping guest data.
            if (slotGuardRunning(dir)) {
                appendLog("Wipe refused: slot '" + slot + "' guest is running — return to One UI first.");
                return;
            }
            // 5.9.5-INT-END
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    // 5.9.6: best-effort lazy unmount of a stale data bind
                    // first (a no-op when nothing is mounted there).
                    "umount -l " + dir + "/data 2>/dev/null || true; "
                    + "if mount | grep -q '" + dir + "/rootfs '; then echo 'SLOT_RUNNING'; "
                    + "else rm -rf " + dir + "/data && echo 'SLOT_WIPED'; fi"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                boolean wiped = false, running = false;
                while ((line = r.readLine()) != null) {
                    if (line.contains("SLOT_WIPED")) wiped = true;
                    if (line.contains("SLOT_RUNNING")) running = true;
                }
                p.waitFor();
                if (running) {
                    appendLog("Wipe refused: slot '" + slot + "' guest is running — return to One UI first.");
                } else if (wiped) {
                    appendLog("Guest data wiped for slot '" + slot + "' (system.raw kept). Next boot starts fresh first-time setup.");
                } else {
                    appendLog("ERROR: Could not wipe slot '" + slot + "' data.");
                }
            } catch (Exception e) {
                appendLog("Wipe slot failed: " + e.getMessage());
            }
        });
    }

    // 5.9.11: wipe-after-install toggle (user-requested). Runs AFTER a
    // successful install, only when the toggle is on, and NEVER fails
    // the install if the wipe itself fails (the install is already
    // good; a failed wipe is a warning, not a rollback). Guest data
    // only — wipeUserDataCmd never touches system.raw — and the slot
    // guard refuses if the guest is somehow running.
    private void wipeAfterInstallIfEnabled() {
        if (!wipeAfterInstall) return;
        try {
            String dir = currentSlotDir();
            if (slotGuardRunning(dir)) {
                appendLog("Wipe-after-install skipped: slot '" + selectedSlot + "' guest is running — install itself is good.");
                return;
            }
            int rc = runRootCmdDrained(wipeUserDataCmd(dir));
            if (rc == 0) {
                appendLog("Guest userdata wiped after install (toggle on) — next boot starts fresh setup. system.raw kept.");
            } else {
                appendLog("WARNING: wipe-after-install did not complete (exit " + rc + ") — install itself is good; use 'Wipe slot data' to retry.");
            }
        } catch (Exception e) {
            appendLog("WARNING: wipe-after-install error (" + e.getMessage() + ") — install itself is good.");
        }
    }

    // 5.9.11: synchronous engine sync (call ONLY from a background
    // thread). Copies the app's engine files (filesDir) into STAGE_DIR
    // so Default-slot installs and the return script find them there.
    // Big binaries (jars, APK, 7zz, simg2img, zygote_exec) are copied
    // only when missing, size-changed, or after an app upgrade
    // (tracked by STAGE_DIR/.sync_version) — re-copying tens of MB
    // of jars on every launch/boot was pure waste. Small files
    // (scripts, flags, version) are always copied so toggles and
    // script updates propagate immediately. Best-effort: failures
    // are ignored here because boot/install syncs cover the slot
    // dirs as well.
    private void syncEngineToStageSync() {
        try {
            String ver = "";
            try { ver = getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception ignored) {}
            String files = getFilesDir().getAbsolutePath();
            // 5.9.16: SHA-256 sync, not size-only. The old skip
            // (same version + same size) kept a same-length stale
            // binary. Now a big binary is skipped only when its
            // live SHA-256 equals the source's; with no hasher on
            // the phone the hash is empty and the file is copied
            // (safe fallback: copy, never skip blind). Scripts are
            // still always copied (good behaviour, kept). After the
            // loop a versioned hash file .engine_hashes ("# version
            // <ver>" + "<sha> <base>" lines) is written so
            // install_image.sh can hash-check 7zz/simg2img before
            // it trusts them.
            String cmd = "VER=" + ver + "; SLOTVER=$(cat " + STAGE_DIR + "/.sync_version 2>/dev/null); "
                    + "hashf() { if command -v sha256sum >/dev/null 2>&1; then sha256sum \"$1\" 2>/dev/null | cut -d' ' -f1; elif command -v busybox >/dev/null 2>&1; then busybox sha256sum \"$1\" 2>/dev/null | cut -d' ' -f1; fi; }; "
                    + "mkdir -p " + STAGE_DIR + "; "
                    + "for f in " + files + "/*; do base=$(basename \"$f\"); "
                    + "case \"$base\" in *.jar|*.apk|7zz|simg2img|zygote_exec) "
                    + "if [ \"$SLOTVER\" = \"$VER\" ]; then s=$(hashf \"$f\"); d=$(hashf \"" + STAGE_DIR + "/$base\"); [ -n \"$s\" ] && [ \"$s\" = \"$d\" ] && continue; fi;; esac; "
                    + "cp -f \"$f\" \"" + STAGE_DIR + "/$base\"; done; "
                    + "echo \"$VER\" > " + STAGE_DIR + "/.sync_version 2>/dev/null; "
                    + "cp -f " + files + "/7zz /data/local/tmp/7zz 2>/dev/null; "
                    + "chmod 755 " + STAGE_DIR + "/*.sh " + STAGE_DIR + "/zygote_exec " + STAGE_DIR + "/7zz " + STAGE_DIR + "/simg2img /data/local/tmp/7zz 2>/dev/null; "
                    + "echo \"# version $VER\" > " + STAGE_DIR + "/.engine_hashes 2>/dev/null; "
                    + "for b in services_patched.jar framework_patched.jar PermissionController_patched.apk 7zz simg2img zygote_exec; do [ -f \"" + STAGE_DIR + "/$b\" ] && h=$(hashf \"" + STAGE_DIR + "/$b\") && [ -n \"$h\" ] && echo \"$h $b\" >> " + STAGE_DIR + "/.engine_hashes 2>/dev/null; done; true";
            Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd}).waitFor();
        } catch (Exception ignored) {}
    }

    private void confirmCleanSlate() {
        new AlertDialog.Builder(this)
            .setTitle("Clean slate — remove ALL guest state?")
            .setMessage("This deletes EVERYTHING the app staged: every slot's system image and guest data, all stage files, cached GSI downloads and partials, and all slot records. After this, every slot shows empty / not installed.\n\nYour Samsung system, apps, and files are NOT touched. The guest must not be running — return to One UI first if it is.\n\nThis cannot be undone.")
            .setPositiveButton("Clean slate", (dialog, which) -> doCleanSlate())
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void doCleanSlate() {
        if (!isRootGranted) {
            appendLog("Clean slate needs root — nothing was deleted.");
            return;
        }
        showFuncBar(pbCleanSlate, tvCleanSlateProgress, "Clean slate — removing all guest state…");
        executor.execute(() -> {
            try {
                // Guard: refuse while ANY guest is running.
                List<String> dirs = new ArrayList<>();
                dirs.add(STAGE_DIR);
                List<String> slotDirs = new ArrayList<>();
                runRootCmdCaptured("ls -d " + STAGE_DIR + "/slots/* 2>/dev/null", slotDirs);
                for (String d : slotDirs) { String t = d.trim(); if (!t.isEmpty()) dirs.add(t); }
                for (String d : dirs) {
                    if (slotGuardRunning(d)) {
                        appendLog("Clean slate refused: a guest is running — return to One UI first, then try again. Nothing was deleted.");
                        hideFuncBar(pbCleanSlate, tvCleanSlateProgress);
                        return;
                    }
                }
                // Stop stray session daemons first so nothing recreates
                // files or fires a return mid-wipe.
                runRootCmdDrained("pkill -9 -f \"boot_watchdog.sh\" 2>/dev/null; pkill -9 -f \"adb_watchdog.sh\" 2>/dev/null; pkill -9 -f \"ims_watchdog.sh\" 2>/dev/null; pkill -9 -f \"ui_activator\" 2>/dev/null; true");
                // 5.9.12: unmount any stale mounts under the stage dir
                // FIRST (a leftover loop/bind mount from a hung guest
                // session makes rm fail and used to yield PARTIAL).
                // Bounded loop, stage dir only — never anything else.
                runRootCmdDrained("n=0; while [ $n -lt 50 ]; do MPTS=$(mount 2>/dev/null | grep -F '" + STAGE_DIR + "' | sed -e 's/^.* on //; s/ type .*//' | sort -ru); [ -n \"$MPTS\" ] || break; for m in $MPTS; do umount -l \"$m\" 2>/dev/null || true; done; n=$((n+1)); sleep 0.1; done; true");
                // Scoped deletes: stage contents + the app's own tmp
                // artifacts. NEVER host /data beyond these paths,
                // NEVER host system. The stage dir itself is kept so
                // the engine can re-sync into it below.
                // 5.9.12: the three globs cover normal files AND
                // dotfiles (5.9.11's `*` missed dotfiles other than
                // .guest_running, which alone could cause PARTIAL).
                // `.[!.]*` excludes `.` and `..`; `..?*` catches
                // dot-dot files without matching `..` itself.
                String wipeCmd = "rm -rf " + STAGE_DIR + "/* " + STAGE_DIR + "/.[!.]* " + STAGE_DIR + "/..?* 2>/dev/null; true";
                runRootCmdDrained(wipeCmd);
                runRootCmdDrained("rm -f /data/local/tmp/adb_watchdog.sh /data/local/tmp/ims_watchdog.sh /data/local/tmp/boot_watchdog.sh /data/local/tmp/ui_activator.log /data/local/tmp/boot_watchdog.log /data/local/tmp/adb_watchdog.log /data/local/tmp/ims_watchdog.log /data/local/tmp/restore_app.log 2>/dev/null; true");
                // Verify the stage is actually empty before claiming it.
                List<String> leftovers = new ArrayList<>();
                runRootCmdCaptured("ls -A " + STAGE_DIR + " 2>/dev/null", leftovers);
                List<String> names = new ArrayList<>();
                for (String l : leftovers) { String t = l.trim(); if (!t.isEmpty()) names.add(t); }
                // 5.9.12: one best-effort chmod + retry for stubborn
                // (e.g. read-only) stage files, then re-check.
                if (!names.isEmpty()) {
                    runRootCmdDrained("chmod -R +w " + STAGE_DIR + " 2>/dev/null; true");
                    runRootCmdDrained(wipeCmd);
                    leftovers = new ArrayList<>();
                    runRootCmdCaptured("ls -A " + STAGE_DIR + " 2>/dev/null", leftovers);
                    names = new ArrayList<>();
                    for (String l : leftovers) { String t = l.trim(); if (!t.isEmpty()) names.add(t); }
                }
                boolean stageClean = names.isEmpty();
                if (!stageClean) {
                    // 5.9.12: PARTIAL keeps records + cache so the app
                    // still shows the TRUE state (slots installed),
                    // logs the leftover names (capped) for diagnosis,
                    // and never claims complete or offers uninstall.
                    StringBuilder sb = new StringBuilder();
                    sb.append("Clean slate PARTIAL: ").append(names.size())
                      .append(" stage file(s) could not be removed, so those slots may still show as installed: ");
                    int shown = Math.min(names.size(), 20);
                    for (int i = 0; i < shown; i++) {
                        if (i > 0) sb.append(", ");
                        sb.append(names.get(i));
                    }
                    if (names.size() > shown) sb.append(", and ").append(names.size() - shown).append(" more");
                    sb.append(". Slot records and cached downloads were KEPT so the app still shows the true state. If a mount is stuck, return to One UI or reboot the phone, then retry clean slate.");
                    appendLog(sb.toString());
                    refreshSlots();
                    refreshSlotInfo();
                    checkImageStatus();
                    updateDownloadButtons();
                    hideFuncBar(pbCleanSlate, tvCleanSlateProgress);
                    return;
                }
                // Stage confirmed empty (before any re-sync): only NOW
                // clear caches + records, then re-sync the engine.
                // App-private caches (no root needed): downloads +
                // partials + picker copies.
                int cacheRemoved = 0;
                try {
                    File cacheDir = getCacheDir();
                    if (cacheDir != null) {
                        File[] files = cacheDir.listFiles();
                        if (files != null) {
                            for (File f : files) {
                                if (f.getName().startsWith("gsi_dl")) { if (f.delete()) cacheRemoved++; }
                            }
                        }
                        File pick = new File(cacheDir, "gsi_pick");
                        if (pick.isDirectory()) {
                            File[] picks = pick.listFiles();
                            if (picks != null) { for (File f : picks) { if (f.delete()) cacheRemoved++; } }
                        }
                    }
                } catch (Exception ignored) {}
                // Slot/prefs records: every slot_* key + slot selection
                // + last boot/install records. Globals (theme, style,
                // source, filesystem, patches, guards) are kept.
                int prefsRemoved = 0;
                try {
                    SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
                    SharedPreferences.Editor e = prefs.edit();
                    for (String k : prefs.getAll().keySet()) {
                        if (k.startsWith("slot_")) { e.remove(k); prefsRemoved++; }
                    }
                    e.remove(PREF_LAST_BOOT);
                    e.remove(PREF_LAST_INSTALL);
                    e.putString(PREF_SLOT, DEFAULT_SLOT);
                    e.putString(PREF_AUTOBOOT_SLOT, DEFAULT_SLOT);
                    e.apply();
                    selectedSlot = DEFAULT_SLOT;
                } catch (Exception ignored) {}
                // Re-sync the engine into the (now empty) stage dir so
                // the next install works without an app restart.
                syncEngineToStageSync();
                appendLog("Clean slate complete: stage contents removed; " + cacheRemoved + " cached download/picker file(s) removed; " + prefsRemoved + " slot record(s) cleared; engine re-synced. Every slot is now empty — install again any time.");
                setLastInstall("Last install: none (clean slate).");
                refreshSlots();
                refreshSlotInfo();
                checkImageStatus();
                updateDownloadButtons();
                hideFuncBar(pbCleanSlate, tvCleanSlateProgress);
                // Offer the app uninstall AFTER a successful wipe, never
                // before (and never on PARTIAL).
                mainHandler.post(this::offerUninstallApp);
            } catch (Exception e) {
                appendLog("Clean slate failed: " + e.getMessage());
                hideFuncBar(pbCleanSlate, tvCleanSlateProgress);
            }
        });
    }

    private void offerUninstallApp() {
        new AlertDialog.Builder(this)
            .setTitle("Clean slate done — uninstall the app too?")
            .setMessage("All guest state is gone. If you want the app itself gone as well, tap Uninstall app — Android will ask you to confirm. Otherwise tap Keep app.")
            .setPositiveButton("Uninstall app", (dialog, which) -> {
                try {
                    Intent intent = new Intent(Intent.ACTION_DELETE, Uri.parse("package:com.cronch.gsiloader"));
                    startActivity(intent);
                } catch (Exception e) {
                    appendLog("Could not open the uninstall screen: " + e.getMessage());
                }
            })
            .setNegativeButton("Keep app", null)
            .show();
    }

    private void verifyGsi() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to verify a GSI!");
            return;
        }
        // 5.9.11: own colorful bar (shown on tap, hidden on completion).
        runBarTask(pbVerify, tvVerifyProgress, "Verifying installed system…", () -> {
            try {
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "if [ ! -f " + currentSystemRaw() + " ]; then echo 'VERIFY: no system.raw installed (slot " + selectedSlot + ")'; exit 0; fi; "
                    + "SZ=$(stat -c %s " + currentSystemRaw() + " 2>/dev/null || echo 0); "
                    + "M0=$(od -An -tx1 -N4 " + currentSystemRaw() + " 2>/dev/null | tr -d ' \n'); "
                    + "ME=$(dd if=" + currentSystemRaw() + " bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'); "
                    + "MX=$(dd if=" + currentSystemRaw() + " bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n'); "
                    + "if [ $M0 = 3aff26ed ]; then echo 'VERIFY: SPARSE image (installing it again converts it automatically)'; "
                    + "elif [ $ME = e2e1f5e0 ]; then echo 'VERIFY: OK EROFS ' $MB ' MB'; "
                    + "elif [ $MX = 53ef ]; then echo 'VERIFY: OK ext4 ' $MB ' MB'; "
                    + "else echo 'VERIFY: UNKNOWN format (not ext4/EROFS/sparse)'; fi"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                while ((line = r.readLine()) != null) appendLog(line);
                p.waitFor();
            } catch (Exception e) {
                appendLog("Verify failed: " + e.getMessage());
            }
        });
    }

    private void installLocalGsi(final String localPath) {
        // 5.9.16: capture the slot NOW (main thread, tap time). The task
        // below used to read selectedSlot/currentSlotDir/currentSystemRaw
        // when it RAN, so a slot switch while the install was queued
        // behind another executor task silently installed into the NEW
        // slot instead of the tapped one.
        final String tapSlot = selectedSlot;
        final String tapSlotDir = currentSlotDir();
        final String tapSystemRaw = currentSystemRaw();
        executor.execute(() -> {
            // 5.9.17: task-start half of the one-install guard (the
            // UI half is in installGsi). A tap queued while another
            // install runs refuses here instead of wiping +
            // reinstalling behind the running job.
            if (!installBusy.compareAndSet(false, true)) {
                appendLog("Install already running — this tap was not queued.");
                return;
            }
            // 5.9.17: invalidate any zombie progress poller from an
            // earlier run before this run starts posting.
            installProgressGen.incrementAndGet();
            setLogStatus("Preparing…");
            appendLog("\n[SETUP] Initializing slot '" + tapSlot + "' at: " + tapSlotDir);
            try {
                runRootCmdDrained("mkdir -p " + tapSlotDir + " && chmod 777 " + tapSlotDir);
                if (!tapSlotDir.equals(STAGE_DIR)) {
                    runRootCmdDrained(installSlotScriptsCmd(tapSlotDir));
                }
                appendLog("[SETUP] Wiping existing guest data for a fresh first setup...");
                runRootCmdDrained(wipeUserDataCmd(tapSlotDir));

                appendLog("[LOCAL INSTALL] Using local file: " + localPath);
                logSparsePrecheck(localPath);
                setLogStatus("Installing…");
                setOperationProgress(-1, "Installing image…", true);
                // 5.9.17: reset the progress file in Java, not just in
                // the script — a pre-script failure (e.g. a missing
                // local file) never runs the script, so the next
                // poller would otherwise replay the previous run's
                // lines, including its "done", over this run's UI.
                runRootCmdDrained("rm -f " + tapSlotDir + "/install_progress.log");
                streamInstallProgress(tapSlotDir);
                List<String> installOut = new ArrayList<>();
                int ret = runRootCmdStreamed(
                        "if [ ! -f " + shQuote(localPath) + " ]; then echo 'LOCAL_FILE_MISSING'; exit 1; fi; "
                        + installImageCmd(localPath, false, tapSlotDir, tapSystemRaw), installOut, true);
                if (ret != 0 || !new File(tapSystemRaw).exists()) {
                    // 5.9.6: surface the script's real reason (e.g. its
                    // INSTALL_ERROR line) instead of a bare exit code. The
                    // old message also wrongly claimed sparse images are
                    // "not converted here" — install_image.sh converts
                    // them with the bundled simg2img.
                    String reason = null;
                    for (String line : installOut) {
                        if (line.contains("INSTALL_ERROR:") || line.contains("LOCAL_FILE_MISSING")) { reason = line; break; }
                    }
                    if (reason == null && !installOut.isEmpty()) reason = installOut.get(installOut.size() - 1);
                    throw new Exception("Local install failed (exit " + ret + ") - system.raw was not produced"
                            + (reason != null ? " — " + reason : "")
                            + ". Nothing was booted; fix the cause above and tap Install again.");
                }
                setOperationProgress(100, "Installed — ready to boot.", true);
                appendLog("✓ Local GSI installed into slot '" + tapSlot + "' -> system.raw ready! CRONCH 🐔🌮");
                // 5.9.17: the picked cache file is KEPT after a good
                // install. Deleting it used to break every later tap:
                // the UI still pointed at the deleted path, so the
                // next install failed instantly with
                // LOCAL_FILE_MISSING while the frozen log hid the
                // reason. system.raw is already a separate copy, so
                // keeping the picked file costs one cache file and
                // keeps "Reinstall GSI" working.
                // 5.9.11: wipe-after-install toggle (user-requested).
                wipeAfterInstallIfEnabled();
                setLogStatus("Ready");
                setLastInstall("Last install: slot '" + tapSlot + "' — local file installed, ready to boot.");
                mainHandler.post(() -> {
                    pbDownload.setVisibility(View.GONE);
                    tvDownloadProgress.setText("Custom GSI installed successfully!");
                });
                // 5.9.17: bump the progress generation so a late
                // poller post can never overwrite the final UI with
                // a stale "Installing: ..." line, then release the
                // one-install guard.
                installProgressGen.incrementAndGet();
                checkImageStatus();
                installBusy.set(false);
            } catch (Exception e) {
                setOperationProgress(0, null, false);
                appendLog("Local install failed: " + e.getMessage());
                setLogStatus("Error");
                mainHandler.post(() -> {
                    pbDownload.setVisibility(View.GONE);
                    tvDownloadProgress.setText("Install failed: " + e.getMessage());
                });
                // 5.9.6: a failed install must leave Boot honestly gated —
                // refresh the image state so Boot cannot run on a stale
                // assumption (see also the bootGsi system.raw guard).
                installProgressGen.incrementAndGet();
                checkImageStatus();
                installBusy.set(false);
            }
        });
    }

    // 5.9.5-APP-START: resume-aware download. Returns false when paused.
    private boolean downloadFileWithRedirects(String initialUrl, File targetFile, long expectedBytes) throws Exception {
        long resumeOffset = 0;
        try {
            File state = new File(getCacheDir(), "gsi_dl.state");
            if (state.exists() && targetFile.exists() && targetFile.length() > 0) {
                BufferedReader sr = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(state)));
                String savedUrl = sr.readLine();
                sr.close();
                if (initialUrl.equals(savedUrl)) resumeOffset = targetFile.length();
            }
        } catch (Exception ignored) { resumeOffset = 0; }
        if (resumeOffset > 0) appendLog("Resuming download at " + (resumeOffset / 1048576) + " MB (HTTP Range).");
        try {
            return downloadFileWithRedirectsFrom(initialUrl, targetFile, expectedBytes, resumeOffset);
        } catch (Exception primary) {
            // 5.9.16: SourceForge mirror fallback. Preset URLs use
            // downloads.sourceforge.net with use_mirror=autoselect;
            // a flaky mirror used to look exactly like a corrupt
            // download. On a mirror failure, retry ONCE against the
            // direct download URL (same path, no autoselect query —
            // SourceForge then serves it directly instead of via
            // the failed mirror pick), from the beginning: a resume
            // across mirrors is exactly how the study's
            // resumed-across-redirect corruption happened, so the
            // partial file and the resume state are dropped first.
            // A pause (method returns false) is NOT an exception
            // and never triggers this fallback. Custom URLs and
            // non-SourceForge failures rethrow untouched.
            boolean isSfMirror = initialUrl != null && initialUrl.contains("sourceforge.net")
                    && initialUrl.contains("use_mirror=autoselect");
            if (!isSfMirror) throw primary;
            String fallbackUrl = initialUrl;
            int q = fallbackUrl.indexOf('?');
            if (q >= 0) fallbackUrl = fallbackUrl.substring(0, q);
            appendLog("SourceForge mirror failed (" + primary.getMessage() + ") — falling back to the direct download URL: " + fallbackUrl);
            try { new File(getCacheDir(), "gsi_dl.state").delete(); } catch (Exception ignored) {}
            try {
                return downloadFileWithRedirectsFrom(fallbackUrl, targetFile, expectedBytes, 0);
            } catch (Exception fallbackEx) {
                throw new Exception("Preset download failed on both the SourceForge mirror and the direct URL (mirror: " + primary.getMessage() + "; direct: " + fallbackEx.getMessage() + ")");
            }
        }
    }

    private boolean downloadFileWithRedirectsFrom(String initialUrl, File targetFile, long expectedBytes, long resumeOffset) throws Exception {
        String currentUrl = initialUrl;
        HttpURLConnection conn = null;
        int redirectCount = 0;
        final int MAX_REDIRECTS = 10;

        while (redirectCount < MAX_REDIRECTS) {
            URL url = new URL(currentUrl);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestProperty("User-Agent", "Wget/1.21.3");
            // 5.9.5-APP-START: Range header for resume.
            if (resumeOffset > 0) conn.setRequestProperty("Range", "bytes=" + resumeOffset + "-");
            // 5.9.5-APP-END
            conn.setRequestProperty("Accept", "*/*");
            conn.setConnectTimeout(25000);
            conn.setReadTimeout(30000);
            conn.setInstanceFollowRedirects(false);

            int code = conn.getResponseCode();
            if (code == HttpURLConnection.HTTP_MOVED_PERM ||
                code == HttpURLConnection.HTTP_MOVED_TEMP ||
                code == HttpURLConnection.HTTP_SEE_OTHER ||
                code == 307 || code == 308) {

                String loc = conn.getHeaderField("Location");
                if (loc == null || loc.trim().isEmpty()) {
                    throw new Exception("Redirect code " + code + " without Location header");
                }
                currentUrl = loc.trim();
                conn.disconnect();
                redirectCount++;
                appendLog("Following mirror redirect [" + redirectCount + "]...");
                continue;
            }

            // 5.9.5-APP-START: 206 = resumed; 200 to a Range request = no Range support.
            if (resumeOffset > 0 && code == HttpURLConnection.HTTP_PARTIAL) {
                break;
            }
            if (resumeOffset > 0 && code == HttpURLConnection.HTTP_OK) {
                appendLog("Download server does not support HTTP Range — restarting download from the beginning.");
                resumeOffset = 0;
                break;
            }
            if (code != HttpURLConnection.HTTP_OK) {
                throw new Exception("HTTP server error code: " + code);
            }
            // 5.9.5-APP-END

            break;
        }

        if (redirectCount >= MAX_REDIRECTS || conn == null) {
            throw new Exception("Too many redirects: " + redirectCount);
        }
        // 5.9.16: record which mirror actually served the file
        // (currentUrl is the final redirect target, i.e. the mirror
        // URL for SourceForge presets) so a bad mirror is visible
        // in the log instead of looking like a corrupt download.
        appendLog("Download served from: " + currentUrl);

        long contentLength = -1;
        try {
            contentLength = Long.parseLong(conn.getHeaderField("Content-Length"));
        } catch (Exception ignored) {}
        final long totalBytes = (contentLength > 0) ? contentLength : expectedBytes;

        mainHandler.post(() -> {
            pbDownload.setMax(100);
            pbDownload.setProgress(0);
        });

        long startMs = System.currentTimeMillis();
        long lastUpdateMs = 0;
        long currentBytes = resumeOffset;

        // 5.9.5-APP-START: append mode when resuming, truncate on restart.
        try (InputStream in = conn.getInputStream();
             OutputStream out = new FileOutputStream(targetFile, resumeOffset > 0)) {

            byte[] buffer = new byte[65536];
            int read;
            while ((read = in.read(buffer)) != -1) {
                if (downloadPauseRequested) {
                    downloadPauseRequested = false;
                    return false;
                }
                out.write(buffer, 0, read);
                currentBytes += read;
        // 5.9.5-APP-END

                long now = System.currentTimeMillis();
                if (now - lastUpdateMs > 250) {
                    lastUpdateMs = now;
                    final int pct = (totalBytes > 0) ? (int) Math.min(100, (currentBytes * 100) / totalBytes) : 0;
                    final long elapsedSec = Math.max(1, (now - startMs) / 1000);
                    final double speedMb = (currentBytes / 1048576.0) / elapsedSec;
                    // Custom URLs may not report a size (expectedBytes=-1 and
                    // no Content-Length): show MB downloaded instead of "-1 MB".
                    final String progStr = (totalBytes > 0)
                            ? String.format("Downloading: %d MB / %d MB (%d%%) • %.1f MB/s",
                                    currentBytes / 1048576, totalBytes / 1048576, pct, speedMb)
                            : String.format("Downloading: %d MB (total unknown) • %.1f MB/s",
                                    currentBytes / 1048576, speedMb);
                    mainHandler.post(() -> {
                        pbDownload.setProgress(pct);
                        tvDownloadProgress.setText(progStr);
                        if (pbOperation != null) { pbOperation.setIndeterminate(false); pbOperation.setMax(100); pbOperation.setProgress(pct); }
                        if (tvOperationProgress != null) tvOperationProgress.setText(progStr);
                    });
                }
            }
            out.flush();
        } finally {
            conn.disconnect();
        }

        if (targetFile.length() < 1000000) {
            throw new Exception("Downloaded file is too small (" + targetFile.length() + " bytes).");
        }
        return true;
    }
    // 5.9.5-APP-END

    private void startNetworkDownload(final String downloadUrl, final long expectedBytes, final String label) {
        startNetworkDownload(downloadUrl, expectedBytes, label, false);
    }

    // 5.9.5-APP-START
    private void startNetworkDownload(final String downloadUrl, final long expectedBytes, final String label, final boolean isResume) {
        executor.execute(() -> {
            // 5.9.17: same one-install-at-a-time guard as the local
            // path, plus ownership transfer for the corrupt-download
            // retry below: the retry task inherits the flag instead
            // of fighting the CAS.
            if (installHandoff) {
                installHandoff = false;
            } else if (!installBusy.compareAndSet(false, true)) {
                appendLog("Install already running — this tap was not queued.");
                return;
            }
            installProgressGen.incrementAndGet();
            setLogStatus("Preparing…");
            downloading = true;
            updateDownloadButtons();
            mainHandler.post(() -> {
                pbDownload.setVisibility(View.VISIBLE);
                pbDownload.setIndeterminate(false);
                pbDownload.setProgress(0);
                tvDownloadProgress.setVisibility(View.VISIBLE);
                tvDownloadProgress.setText("Connecting to download source…");
                setOperationProgress(0, "Connecting…", true);
                refreshInstallEnabled();
            });

            appendLog("\n[SETUP] Initializing slot '" + selectedSlot + "' at: " + currentSlotDir());
            try {
                // 5.9.5-APP-START
                lastDownloadUrl = downloadUrl;
                lastDownloadExpected = expectedBytes;
                lastDownloadLabel = label;
                runRootCmdDrained("mkdir -p " + currentSlotDir() + " && chmod 777 " + currentSlotDir());
                if (!isDefaultSlot()) {
                    // 5.9.6: named slots need simg2img too (sparse conversion).
                    runRootCmdDrained(installSlotScriptsCmd(currentSlotDir()));
                }
                if (!isResume) {
                    appendLog("[SETUP] Wiping existing guest data for a fresh first setup...");
                    runRootCmdDrained(wipeUserDataCmd(currentSlotDir()));
                } else {
                    appendLog("[RESUME] Keeping existing slot data; resuming download only.");
                }
                // 5.9.5-APP-END

                // Download into the app's own cache dir, NOT STAGE_DIR directly: this
                // process writes as the unprivileged app, and /data/local/tmp paths
                // created by root are labeled shell_data_file, which SELinux blocks
                // untrusted_app from writing to no matter what chmod says (this is the
                // actual cause of "gsi_dl: open failed: EACCES"). su (used below
                // for extraction) can read the app's cache dir fine, same as
                // extractAssets() already does for the other staged files.
                // Keep a real extension when the URL has one: 7zz uses it to
                // detect the archive type, and a bare .img URL is a raw image.
                String cacheName = "gsi_dl.bin";
                String lowerUrl = downloadUrl.toLowerCase();
                for (String ext : new String[]{".7z", ".zip", ".xz", ".img", ".img.xz"}) {
                    if (lowerUrl.contains(ext) && (lowerUrl.endsWith(ext)
                            || lowerUrl.indexOf(ext + "?") >= 0 || lowerUrl.indexOf(ext + "&") >= 0)) {
                        cacheName = "gsi_dl" + ext;
                        break;
                    }
                }
                final File targetArchive = new File(getCacheDir(), cacheName);
                // 5.9.5-APP-START: persist resume state (URL) for pause/resume.
                // Read the PREVIOUS state before overwriting it, so a fresh
                // download of a different URL drops the stale partial file.
                try {
                    File state = new File(getCacheDir(), "gsi_dl.state");
                    String prev = null;
                    if (state.exists()) {
                        try {
                            BufferedReader sr = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(state)));
                            prev = sr.readLine();
                            sr.close();
                        } catch (Exception ignored) {}
                    }
                    try (OutputStream sout = new FileOutputStream(state)) {
                        sout.write(downloadUrl.getBytes("UTF-8"));
                    }
                    if (!isResume && targetArchive.exists() && (prev == null || !prev.equals(downloadUrl))) {
                        targetArchive.delete();
                    }
                } catch (Exception ignored) {}

                appendLog("[NETWORK DOWNLOAD] Fetching " + label + " directly via native HTTP engine...");
                appendLog("URL: " + downloadUrl);
                setLogStatus("Downloading…");

                boolean completed = downloadFileWithRedirects(downloadUrl, targetArchive, expectedBytes);
                if (!completed) {
                    appendLog("Download PAUSED at " + (targetArchive.length() / 1048576) + " MB — tap Resume download to continue (partial file kept).");
                    setLogStatus("Paused");
                    downloading = false;
                    installBusy.set(false);
                    updateDownloadButtons();
                    mainHandler.post(() -> {
                        pbDownload.setVisibility(View.VISIBLE);
                        tvDownloadProgress.setText("Paused at " + (targetArchive.length() / 1048576) + " MB — tap Resume.");
                        setOperationProgress(-1, "Paused at " + (targetArchive.length() / 1048576) + " MB — tap Resume.", true);
                        refreshInstallEnabled();
                    });
                    return;
                }
                try { new File(getCacheDir(), "gsi_dl.state").delete(); } catch (Exception ignored) {}
                // 5.9.5-APP-END

                appendLog("✓ Download completed successfully! (" + (targetArchive.length() / 1048576) + " MB)");
                setLogStatus("Extracting…");
                mainHandler.post(() -> {
                    pbDownload.setIndeterminate(true);
                    tvDownloadProgress.setText("Decompressing image with ARM64 7-Zip…");
                    setOperationProgress(-1, "Extracting image…", true);
                });

                appendLog("Installing " + targetArchive.getAbsolutePath() + " via native 7zz...");
                // 5.9.17: same Java-side progress-file reset as the
                // local path, so a poller can never replay a previous
                // run's lines over this run's UI.
                runRootCmdDrained("rm -f " + currentSlotDir() + "/install_progress.log");
                streamInstallProgress(currentSlotDir());
                List<String> installOut = new ArrayList<>();
                int extRet = runRootCmdStreamed(installImageCmd(targetArchive.getAbsolutePath(), true)
                        + "; rm -f " + shQuote(targetArchive.getAbsolutePath()), installOut, true);
                if (extRet != 0 || !new File(currentSystemRaw()).exists()) {
                    // 5.9.6: report the script's real reason, not a bare
                    // exit code (and never the stale "sparse images are not
                    // converted here" claim — install_image.sh converts
                    // them with the bundled simg2img).
                    String reason = null;
                    for (String line : installOut) {
                        if (line.contains("INSTALL_ERROR:")) { reason = line; break; }
                    }
                    if (reason == null && !installOut.isEmpty()) reason = installOut.get(installOut.size() - 1);
                    // 5.9.9: a corrupt download (archive failed its
                    // integrity test, typically a resumed transfer that
                    // reassembled badly) is retried ONCE automatically
                    // with a fresh full download — no resume, because the
                    // chained rm -f above already deleted the bad file
                    // and the state file was deleted after the download.
                    // The retry is queued as a new executor task and this
                    // task returns without touching the downloading flag
                    // or the error UI; the retry owns them from here.
                    if (reason != null && reason.contains("DOWNLOAD_CORRUPT") && !corruptDownloadRetried) {
                        corruptDownloadRetried = true;
                        try { targetArchive.delete(); } catch (Exception ignored) {}
                        try { new File(getCacheDir(), "gsi_dl.state").delete(); } catch (Exception ignored) {}
                        appendLog("Corrupt download detected — deleting it and fetching a fresh copy automatically (no resume)…");
                        // 5.9.17: hand the busy flag to the retry task
                        // instead of clearing it — a tap landing in
                        // between must still see "already running".
                        installHandoff = true;
                        startNetworkDownload(downloadUrl, expectedBytes, label, false);
                        return;
                    }
                    String suffix = ". Nothing was booted; fix the cause above and tap Install again.";
                    if (reason != null && reason.contains("DOWNLOAD_CORRUPT")) {
                        suffix = " — the corrupt download was deleted; tapping Install again fetches a fresh copy (not a resume)."
                                + " Nothing was booted.";
                    }
                    throw new Exception("Install failed (exit " + extRet + ") - system.raw was not produced"
                            + (reason != null ? " — " + reason : "")
                            + suffix);
                }

                appendLog("✓ Installation complete into slot '" + selectedSlot + "' -> system.raw ready!");
                downloading = false;
                updateDownloadButtons();
                setLastInstall("Last install: slot '" + selectedSlot + "' — " + label + " installed, ready to boot.");
                // 5.9.11: wipe-after-install toggle (user-requested).
                wipeAfterInstallIfEnabled();

                mainHandler.post(() -> {
                    pbDownload.setVisibility(View.GONE);
                    tvDownloadProgress.setText(label + " installed successfully!");
                    setOperationProgress(100, "Installed — ready to boot.", true);
                    refreshInstallEnabled();
                });
                setLogStatus("Ready");
                // 5.9.17: same progress-generation bump + guard
                // release as the local path (see there).
                installProgressGen.incrementAndGet();
                checkImageStatus();
                installBusy.set(false);

            } catch (Exception e) {
                appendLog("Download / setup failed: " + e.getMessage());
                setLogStatus("Error");
                downloading = false;
                updateDownloadButtons();
                mainHandler.post(() -> {
                    pbDownload.setVisibility(View.GONE);
                    tvDownloadProgress.setText("Setup failed: " + e.getMessage());
                    setOperationProgress(0, null, false);
                    refreshInstallEnabled();
                });
                // 5.9.6: refresh the image state so Boot stays honestly
                // gated after a failed install (see bootGsi's guard).
                installProgressGen.incrementAndGet();
                checkImageStatus();
                installBusy.set(false);
            }
        });
    }

    // 5.9.5-APP-END

    // Unmounts the container rootfs and detaches any loop device backed by a file
    // under STAGE_DIR. Bounded retry loop (not an unbounded "while mount|grep" loop)
    // so it can never hang forever, and retries losetup -d once since EBUSY is often
    // transient right after pkill -9 (kernel hasn't finished releasing the dying
    // container's private mount namespace yet).
    private String containerUnmountCmd(String stageDir) {
        String rootfs = stageDir + "/rootfs";
        return "BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox); " +
               "[ -x \"$BB\" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1); " +
               "umount -l " + rootfs + "/apex/* 2>/dev/null || true; " +
               "umount -l " + rootfs + "/* 2>/dev/null || true; " +
               "umount -l " + rootfs + " 2>/dev/null || true; " +
               "n=0; while [ $n -lt 50 ] && mount | grep -q '" + rootfs + "'; do " +
               "  umount -l " + rootfs + " 2>/dev/null || true; " +
               "  n=$((n+1)); sleep 0.1; " +
               "done; " +
               "if [ -x \"$BB\" ]; then " +
               "  for l in $($BB losetup -a | grep -F '" + stageDir + "' | cut -d: -f1); do " +
               "    $BB losetup -d \"$l\" 2>/dev/null || { sleep 0.3; $BB losetup -d \"$l\" 2>/dev/null || true; }; " +
               "  done; " +
               "fi";
    }

    private String wipeUserDataCmd(String stageDir) {
        return containerUnmountCmd(stageDir) + "; " +
               "rm -rf " + stageDir + "/data " + stageDir + "/rootfs; mkdir -p " + stageDir + "/rootfs";
    }

    private void confirmDeleteGsi() {
        new AlertDialog.Builder(this)
            .setTitle("Delete guest files for slot '" + selectedSlot + "'?")
            .setMessage("This stops the slot's guest if it is running, unmounts it, detaches its loop mounts, and removes its system image, its backup, and its guest data to free up several GB. The slot itself stays (for Default, this is how you remove its system). You can install again any time. This is NOT the same as Wipe slot data, which keeps the system image and only clears guest data.")
            .setPositiveButton("Delete", (dialog, which) -> deleteGsi())
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void deleteGsi() {
        // 5.9.11: own colorful bar (slot ops share one bar).
        runBarTask(pbSlot, tvSlotProgress, "Deleting guest files…", () -> {
            setLogStatus("Cleaning…");
            appendLog("\n[CLEANUP] Stopping running container processes & unmounting...");
            try {
                // Only kill zygote64/surfaceflinger/vold/system_server by name if the
                // guest container's rootfs is actually mounted. If it isn't (e.g.
                // we're sitting on stock One UI with no switch in progress), those
                // pidof lookups resolve to the HOST's own real daemons - killing them
                // crashes/reboots the device instead of cleaning up a container.
                String cleanupCmd =
                    "if mount | grep -q '" + currentRootfs() + " '; then " +
                    "  pkill -9 -f 'ctl.stop zygote' 2>/dev/null || true; " +
                    "  pkill -9 -f 'ui_activator' 2>/dev/null || true; " +
                    "  pkill -9 -f 'zygote_exec' 2>/dev/null || true; " +
                    "  pkill -9 -f 'system_server' 2>/dev/null || true; " +
                    // No guest-brand process kills here: killing system_server
                    // above takes the whole guest userspace with it, and a
                    // brand-specific pattern (previously org.lineageos) would
                    // miss every other GSI anyway.
                    "  pkill -9 -x zygote64 2>/dev/null || true; " +
                    "  kill -9 $(pidof surfaceflinger) 2>/dev/null || true; " +
                    "  kill -9 $(pidof bootanimation) 2>/dev/null || true; " +
                    // Matched by the container's distinctive vold launch flags, never
                    // "pidof vold" bare - that would kill the HOST's real vold too if
                    // both happened to be alive, crashing the device (confirmed live).
                    "  pkill -9 -f 'blkid_context=u:r:blkid:s0' 2>/dev/null || true; " +
                    "  sleep 0.3; " +
                    "fi; " +
                    containerUnmountCmd(currentSlotDir()) + "; " +
                    // If a loop device is still stuck busy (namespace teardown lagging),
                    // truncating frees the backing blocks immediately even though rm -f
                    // alone would leave them held open by that loop device.
                    "truncate -s 0 " + currentSystemRaw() + " 2>/dev/null || true; " +
                    // 5.9.6: the single backup (.bak) is part of the slot's
                    // guest files — 5.9.5 left the multi-GB backup behind
                    // while claiming the files were deleted.
                    "rm -f " + currentSystemRaw() + " " + currentSystemRaw() + ".bak " + currentSlotDir() + "/*.img " + currentSlotDir() + "/*.7z " + currentSlotDir() + "/*.img.tmp; " +
                    "rm -rf " + currentSlotDir() + "/data " + currentSlotDir() + "/rootfs; " +
                    "mkdir -p " + currentSlotDir() + "/rootfs; " +
                    "if [ -f " + currentSystemRaw() + " ]; then echo 'WARNING: system.raw still present!'; else echo 'Container unmounted, data wiped, and storage freed.'; fi";

                Process p = new ProcessBuilder(suBinary, "-c", cleanupCmd).redirectErrorStream(true).start();
                BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                boolean stillPresent = false;
                while ((line = reader.readLine()) != null) {
                    appendLog("  " + line);
                    if (line.contains("WARNING: system.raw still present")) {
                        stillPresent = true;
                    }
                }
                p.waitFor();
                if (stillPresent) {
                    appendLog("✗ system.raw could not be fully removed (a loop device is still holding it busy). Try again, or reboot and retry.");
                    setLogStatus("Error");
                } else {
                    appendLog("✓ GSI files deleted cleanly. All loop mounts detached!");
                    setLogStatus("Idle");
                }
                checkImageStatus();
            } catch (Exception e) {
                appendLog("Delete failed: " + e.getMessage());
                setLogStatus("Error");
            }
        });
    }

    private void bootGsi() {
        long nowTap = System.currentTimeMillis();
        if (nowTap - lastBootTapMs < 500) return;
        lastBootTapMs = nowTap;
        final String bootSlot = selectedSlot;
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to boot the GSI!");
            return;
        }
        // 5.9.5-APP-START: battery guard for slot-switch (boot).
        if (!batteryGuardAllows("boot", () -> bootGsi())) return;
        // 5.9.5-APP-END
        // 5.9.11: engine gate (see extractAssets): never boot from a
        // half-unpacked engine. The unpack takes ~a second after a
        // cold start, so this only bites an instant tap — and it
        // says so instead of failing weirdly mid-takeover.
        if (!assetsReady) {
            appendLog("Engine still unpacking — tap Boot again in a second.");
            extractAssets();
            return;
        }
        appendLog("\n[START] Preparing guest boot...");
        setLogStatus("Switching…");
        setOperationProgress(-1, "Booting guest…", true);
        // 5.9.6: flush a typed custom density now (main thread — it reads
        // Views), before the executor task writes the flags file.
        flushDensityField();
        executor.execute(() -> {
            try {
                // 5.9.6 SAFETY GATE (on-device 5.9.5 bug): never spawn the
                // takeover when the picked slot has no installed system.
                // 5.9.5 let the boot-menu button (never disabled) spawn a
                // takeover right after a failed install, logging success
                // for a switch that could not work. Refuse here, before
                // any spawn and before counting a boot.
                String bootDir = currentSlotDir();
                if (runRootCmdDrained("[ -f " + bootDir + "/system.raw ]") != 0) {
                    appendLog("Boot refused: slot '" + bootSlot + "' has no installed system image — tap Install first. Nothing was started.");
                    setLogStatus("Error");
                    setOperationProgress(0, null, false);
                    return;
                }
                // Write flags synchronously first: the sync below must carry
                // the current toggles, not a still-pending background write.
                saveGsiPrefs();
                writeGsiFlagsFileSync();
                File filesDir = getFilesDir();
                String slotDir = currentSlotDir();
                // 5.9.16: SHA-256 boot sync (same scheme as
                // syncEngineToStageSync, 5.9.16): big binaries are
                // skipped only when their live SHA-256 matches, not
                // on version + size; scripts and flags are always
                // copied so toggles propagate, and patched files are
                // still removed when their toggles are off (good
                // behaviours, kept). The versioned .engine_hashes
                // file is written AFTER the toggle removals below,
                // so it never lists a file the sync just removed.
                String bootVer = "";
                try { bootVer = getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception ignored) {}
                String syncCmd = "VER=" + bootVer + "; SLOTVER=$(cat " + slotDir + "/.sync_version 2>/dev/null); "
                        + "hashf() { if command -v sha256sum >/dev/null 2>&1; then sha256sum \"$1\" 2>/dev/null | cut -d' ' -f1; elif command -v busybox >/dev/null 2>&1; then busybox sha256sum \"$1\" 2>/dev/null | cut -d' ' -f1; fi; }; "
                        + "mkdir -p " + slotDir + "; for f in " + filesDir.getAbsolutePath() + "/*; do "
                        + "base=$(basename \"$f\"); "
                        + "case \"$base\" in *.jar|*.apk|7zz|simg2img|zygote_exec) "
                        + "if [ \"$SLOTVER\" = \"$VER\" ]; then s=$(hashf \"$f\"); d=$(hashf \"" + slotDir + "/$base\"); [ -n \"$s\" ] && [ \"$s\" = \"$d\" ] && continue; fi;; esac; "
                        + "cp -f \"$f\" \"" + slotDir + "/$base\"; done; "
                        + "echo \"$VER\" > " + slotDir + "/.sync_version 2>/dev/null; "
                        + "chmod 755 " + slotDir + "/*.sh " + slotDir + "/zygote_exec " + slotDir + "/7zz " + slotDir + "/simg2img";
                // Defense in depth: even if a stale patched file from an
                // earlier Lineage install is sitting in STAGE_DIR, a
                // disabled toggle must not leave it where master_prepare.sh
                // could find it. (The script also checks the flags.)
                if (!patchFramework) {
                    syncCmd += " ; rm -f " + slotDir + "/services_patched.jar " + slotDir + "/framework_patched.jar";
                }
                if (!patchPermissionController) {
                    syncCmd += " ; rm -f " + slotDir + "/PermissionController_patched.apk";
                }
                syncCmd += " ; echo \"# version $VER\" > " + slotDir + "/.engine_hashes 2>/dev/null; "
                        + "for b in services_patched.jar framework_patched.jar PermissionController_patched.apk 7zz simg2img zygote_exec; do [ -f \"" + slotDir + "/$b\" ] && h=$(hashf \"" + slotDir + "/$b\") && [ -n \"$h\" ] && echo \"$h $b\" >> " + slotDir + "/.engine_hashes 2>/dev/null; done; true";
                Runtime.getRuntime().exec(new String[]{suBinary, "-c", syncCmd}).waitFor();
                // 5.9.5-INT-START: persist detected framework version for scripts.
                if (detectedFrameworkVersion != null && !detectedFrameworkVersion.isEmpty() && !detectedFrameworkVersion.equals("unknown")) {
                    try { Runtime.getRuntime().exec(new String[]{suBinary, "-c", "echo " + detectedFrameworkVersion + " > " + slotDir + "/framework_version"}).waitFor(); } catch (Exception ignored) {}
                }
                // 5.9.5-INT-END

                String stageScript = slotDir + "/switch_to_gsi.sh";
                // 5.9.5-APP-START: boot env vars for the scripts workstream.
                String bootEnv = "DENSITY_DPI=" + densityForSlot(bootSlot)
                        + " SHARE_FOLDER=" + (shareForSlot(bootSlot) ? "1" : "0")
                        + " FRAMEWORK_VERSION=" + detectedFrameworkVersion
                        + " GUEST_ROOT=" + (guestRootForSlot(bootSlot) ? "1" : "0") + " ";
                // 5.9.6: IMS/DEV/CODEC env vars removed with their dead
                // toggles (no script read them; IMS keepalive is
                // unconditional in switch_to_gsi.sh).
                String cmd = "stageScript=" + stageScript + "; " +
                             "chmod 755 $stageScript; " +
                             "BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox); " +
                             // 5.9.11: bounded busybox search (was an unbounded
                             // find over all of /data — minutes on a full
                             // phone when busybox was not at the default
                             // path). Likely locations only, depth 3.
                             "[ -x \"$BB\" ] || BB=$(find /data/adb /system/bin /system/xbin /vendor/bin -maxdepth 3 -name busybox 2>/dev/null | head -n 1); " +
                             "if [ -n \"$BB\" ] && [ -x \"$BB\" ]; then " +
                             "  " + bootEnv + "$BB setsid /system/bin/sh $stageScript " + slotDir + " </dev/null >" + slotDir + "/takeover_app.log 2>&1 & " +
                             "else " +
                             "  " + bootEnv + "nohup /system/bin/sh $stageScript " + slotDir + " </dev/null >" + slotDir + "/takeover_app.log 2>&1 & " +
                             "fi";
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd});
                p.waitFor();
                recordBoot(bootSlot);
                refreshSlotInfo();
                // 5.9.11: stream the takeover log while the host UI is
                // still visible, instead of jumping to 100% and going
                // silent during the ~minute takeover (IMS gate + guest
                // prepare). The takeover itself is detached; this only
                // reports on it. Polling stops when the takeover
                // launches (the screen is about to switch, so the app
                // UI goes away by design) or after 180s, whichever
                // first — the boot watchdog (10 min) owns the window
                // after that.
                appendLog("Boot watchdog armed (10 min) — if the guest never reaches home, the phone returns to One UI automatically.");
                showFuncBar(pbBoot, tvBootProgress, "Booting guest…");
                streamBootProgress(slotDir, bootSlot);
                // 5.9.6: also refresh the battery readout after a boot tap,
                // so the guard state shown is never stale.
                refreshBattery();
            } catch (Exception e) {
                appendLog("Launch error: " + e.getMessage());
                setLogStatus("Error");
                setOperationProgress(0, null, false);
            }
        });
    }

    // 5.9.11: poll the takeover log and mirror its progress into the
    // app log + the Boot bar while the host UI is still alive. Uses
    // tail -n +K so each poll reads only NEW lines (the log is
    // append-only during one boot). Stops at TAKEOVER LAUNCHED or
    // after 180s; the takeover itself is unaffected by this stopping.
    // 5.9.16: runs on pollExecutor, NOT the root-mutation executor:
    // a hung stream must never wedge install/boot/wipe. Log-file
    // reads tolerate concurrent appends (tail -n +K re-reads the
    // file each poll; a truncated/rotated log just restarts the
    // count at the new tail, it never crashes the poller), and all
    // UI updates go through mainHandler-posted helpers.
    private void streamBootProgress(final String slotDir, final String bootSlot) {
        pollExecutor.execute(() -> {
            try {
                String logPath = slotDir + "/takeover_app.log";
                int total = 0;
                int stage = 0;
                for (int poll = 0; poll < 60; poll++) { // 60 x 3s = 180s
                    Thread.sleep(3000);
                    List<String> fresh = new ArrayList<>();
                    runRootCmdCaptured("tail -n +" + (total + 1) + " " + logPath + " 2>/dev/null", fresh);
                    for (String line : fresh) {
                        appendLog(line);
                        if (line.contains("IMS gate: waiting") && stage < 20) {
                            stage = 20;
                            showFuncBarPct(pbBoot, tvBootProgress, 20, "Waiting for modem IMS registration… (up to 90s)");
                        } else if (line.contains("[1/6]") && stage < 30) {
                            stage = 30; showFuncBarPct(pbBoot, tvBootProgress, 30, "Booting guest… (step 1 of 6)");
                        } else if (line.contains("[2/6]") && stage < 40) {
                            stage = 40; showFuncBarPct(pbBoot, tvBootProgress, 40, "Booting guest… (step 2 of 6)");
                        } else if (line.contains("[3/6]") && stage < 50) {
                            stage = 50; showFuncBarPct(pbBoot, tvBootProgress, 50, "Booting guest… (step 3 of 6)");
                        } else if (line.contains("[4/6]") && stage < 60) {
                            stage = 60; showFuncBarPct(pbBoot, tvBootProgress, 60, "Booting guest… (step 4 of 6)");
                        } else if (line.contains("[5/6]") && stage < 70) {
                            stage = 70; showFuncBarPct(pbBoot, tvBootProgress, 70, "Booting guest… (step 5 of 6)");
                        } else if (line.contains("[6/6]") && stage < 80) {
                            stage = 80; showFuncBarPct(pbBoot, tvBootProgress, 80, "Launching guest…");
                        } else if (line.contains("TAKEOVER LAUNCHED")) {
                            showFuncBarPct(pbBoot, tvBootProgress, 100, "Guest takeover launched — screen switching to guest…");
                            appendLog("Guest takeover launched for slot '" + bootSlot + "' — the screen should switch to the guest now. Boot watchdog armed (10 min): if the guest never reaches home, the phone returns to One UI automatically.");
                            hideFuncBar(pbBoot, tvBootProgress);
                            return;
                        }
                    }
                    total += fresh.size();
                }
                // 180s without a launch: the takeover may still be
                // running (it is detached and unaffected by this
                // polling stopping). Say so honestly and point at
                // the watchdog, instead of claiming 100%.
                showFuncBarPct(pbBoot, tvBootProgress, 90, "Takeover still running — see log.");
                appendLog("Takeover still running after 3 minutes (check the takeover log for where it is). The boot watchdog will return the phone to One UI automatically if the guest never reaches home within 10 minutes.");
            } catch (Exception e) {
                appendLog("Boot progress streaming stopped: " + e.getMessage());
            }
        });
    }

    // 5.9.13: all stage dirs (root Default + named slots) for guard
    // sweeps and light-path checks. Root is always first.
    private List<String> allStageDirs() {
        List<String> dirs = new ArrayList<>();
        dirs.add(STAGE_DIR);
        List<String> slotDirs = new ArrayList<>();
        runRootCmdCaptured("ls -d " + STAGE_DIR + "/slots/* 2>/dev/null", slotDirs);
        for (String d : slotDirs) { String t = d.trim(); if (!t.isEmpty()) dirs.add(t); }
        return dirs;
    }

    // 5.9.13: true if ANY stage dir has a guest actually running
    // (liveness guard: mount/process, never the marker alone).
    private boolean anyGuestRunning(List<String> dirs) {
        for (String d : dirs) { if (slotGuardRunning(d)) return true; }
        return false;
    }

    // 5.9.13: delete .guest_running markers for the given dirs and
    // return how many were actually present. Callers must already
    // have established (via the liveness guard) that no guest is
    // running for these dirs — this helper only deletes breadcrumbs,
    // it never decides liveness itself.
    private int clearGuestMarkers(List<String> dirs) {
        int cleared = 0;
        for (String d : dirs) {
            List<String> has = new ArrayList<>();
            runRootCmdCaptured("[ -f " + d + "/.guest_running ] && echo YES || echo NO", has);
            boolean exists = false;
            for (String h : has) { if ("YES".equals(h.trim())) { exists = true; break; } }
            if (!exists) continue;
            int rc = runRootCmdDrained("rm -f " + d + "/.guest_running 2>/dev/null");
            if (rc == 0) cleared++;
        }
        return cleared;
    }

    private String slotDisplayName(String dir) {
        if (dir.equals(STAGE_DIR)) return "Default";
        int slash = dir.lastIndexOf('/');
        return slash >= 0 ? dir.substring(slash + 1) : dir;
    }

    // 5.9.13: self-heal for stale .guest_running markers. A
    // force-restart never runs return_to_oneui.sh, so the marker
    // survives and every guard used to false-positive ("a guest is
    // running" when none is). The guard is now liveness-based
    // (mount/process, not the marker), so this sweep just removes
    // the stale breadcrumb: for each stage dir, if the guard says
    // NOT running but a marker file exists, the marker is stale —
    // delete it and say so. Runs on every resume (cheap, silent
    // when nothing is stale). Slot "installed" display is
    // unaffected: it reads system.raw files, never the marker.
    // Safety: a marker is deleted only when the liveness guard says
    // that slot's guest is NOT running; a live guest's marker is
    // never touched. And the marker is only created after the rootfs
    // mount exists (switch_to_gsi.sh touches it after
    // master_prepare), so a marker with no mount/process cannot be
    // a takeover in progress — it is always stale. If markers were
    // cleared (meaning the last guest session ended without a
    // Return — a reboot or force-restart), also run the pstore
    // check: it distinguishes a kernel panic during that session
    // from a userspace/manual reboot, which is exactly what an
    // EROFS boot that runs for minutes then restarts needs.
    private void sweepStaleGuestMarkers() {
        if (!isRootGranted) return;
        executor.execute(() -> {
            try {
                List<String> dirs = allStageDirs();
                List<String> stale = new ArrayList<>();
                for (String d : dirs) {
                    if (slotGuardRunning(d)) continue;
                    List<String> has = new ArrayList<>();
                    runRootCmdCaptured("[ -f " + d + "/.guest_running ] && echo YES || echo NO", has);
                    for (String h : has) { if ("YES".equals(h.trim())) { stale.add(d); break; } }
                }
                if (stale.isEmpty()) return;
                int cleared = clearGuestMarkers(stale);
                if (cleared <= 0) return;
                StringBuilder names = new StringBuilder();
                for (String d : stale) { if (names.length() > 0) names.append(", "); names.append(slotDisplayName(d)); }
                appendLog("Cleared " + cleared + " stale guest-running marker(s) (" + names + ") — no guest was actually running (likely left by a force-restart). Guards will no longer refuse on this stale state.");
                // Post-reboot verdict: did the last guest session end
                // in a kernel panic, or a userspace/manual reboot?
                String pstoreScript = new File(getFilesDir(), "pstore_check.sh").getAbsolutePath();
                List<String> verdict = new ArrayList<>();
                runRootCmdCaptured("sh \"" + pstoreScript + "\" 2>/dev/null", verdict);
                for (String v : verdict) appendLog(v);
                // 5.9.16: record the per-slot outcome of that ended
                // session. Precedence: a pstore panic verdict beats
                // everything (it is how the session ended); else a
                // "Home activated!" line in the Activator log means
                // the guest DID reach home before the reboot, so the
                // outcome is home, not a failed boot; otherwise the
                // session ended by reboot / force-restart with no
                // home signal. The Activator log is truncated fresh
                // at every takeover, so a match belongs to the last
                // session, not an older one.
                boolean panic = false;
                for (String v : verdict) if (v.contains("PSTORE_PANIC")) { panic = true; break; }
                List<String> homeCheck = new ArrayList<>();
                runRootCmdCaptured("grep -q 'Home activated!' /data/local/tmp/ui_activator.log 2>/dev/null && echo HOME || echo NOHOME", homeCheck);
                boolean reachedHome = false;
                for (String h : homeCheck) if ("HOME".equals(h.trim())) { reachedHome = true; break; }
                String outcome = panic ? "panic" : (reachedHome ? "home" : "reboot");
                for (String d : stale) noteLastBootOutcome(slotDisplayName(d), outcome);
            } catch (Exception ignored) {}
        });
    }

    // 5.9.11: if the boot watchdog fired on the last guest boot, tell
    // the user once (and delete the marker so it never repeats).
    // Called from onResume, so it surfaces when the app is next
    // opened after a watchdog-triggered return.
    private void surfaceWatchdogOutcome() {
        executor.execute(() -> {
            try {
                List<String> hits = new ArrayList<>();
                runRootCmdCaptured("ls " + STAGE_DIR + "/boot_watchdog_timeout " + STAGE_DIR + "/slots/*/boot_watchdog_timeout 2>/dev/null", hits);
                if (hits.isEmpty()) return;
                appendLog("Last guest boot did not reach the home screen within 10 minutes — the watchdog returned the phone to One UI automatically. Check the takeover log for where it stalled; the guest itself was kept, so you can try booting again.");
                // 5.9.16: record the watchdog-timeout outcome per
                // slot (marker path -> slot) before the markers are
                // deleted below, so the slot picker/card show it.
                for (String hit : hits) {
                    String h = hit.trim();
                    if (!h.isEmpty()) noteLastBootOutcome(slotDisplayName(dirOf(h)), "timeout");
                }
                // 5.9.13: surface the watchdog-timeout diagnostics the
                // watchdog captured before returning (bounded: first
                // 200 lines per slot — the bundle's section headers
                // and earliest failures, which name the stall). Then
                // delete the diagnostics + timeout markers so each
                // failed boot is reported exactly once.
                List<String> diagPaths = new ArrayList<>();
                runRootCmdCaptured("ls " + STAGE_DIR + "/boot_diagnostics.log " + STAGE_DIR + "/slots/*/boot_diagnostics.log 2>/dev/null", diagPaths);
                for (String dp : diagPaths) {
                    String d = dp.trim();
                    if (d.isEmpty()) continue;
                    appendLog("--- Boot diagnostics for " + slotDisplayName(dirOf(d)) + " (paste this back if the boot still fails) ---");
                    List<String> diag = new ArrayList<>();
                    runRootCmdCaptured("head -200 \"" + d + "\" 2>/dev/null", diag);
                    for (String dl : diag) appendLog(dl);
                    runRootCmdDrained("rm -f \"" + d + "\" 2>/dev/null");
                }
                runRootCmdDrained("rm -f " + STAGE_DIR + "/boot_watchdog_timeout " + STAGE_DIR + "/slots/*/boot_watchdog_timeout 2>/dev/null");
            } catch (Exception ignored) {}
        });
    }

    // 5.9.13: parent dir of a file path (for diagnostics labels).
    private String dirOf(String path) {
        int slash = path.lastIndexOf('/');
        return slash > 0 ? path.substring(0, slash) : path;
    }

    // 5.9.5-APP-END

    private void returnToOneUI() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to restore One UI!");
            return;
        }
        appendLog("\n[START] Restoring One UI and resetting display...");
        setLogStatus("Restoring…");
        // 5.9.11: the Return bar shows live progress (was: "triggered"
        // then silence while the return took 10-30s — the "takes
        // forever" complaint).
        showFuncBar(pbReturn, tvReturnProgress, "Returning to One UI…");
        executor.execute(() -> {
            try {
                // 5.9.13 LIGHT PATH: if no guest is actually running
                // (liveness guard across all slots), Return must NOT
                // run the heavy 5-step restore (killing host daemons,
                // restarting host services) just to clear a false
                // state. A stale marker alone is not a guest: clear
                // it and report "already in One UI". The full restore
                // below stays for a genuinely running guest.
                if (!anyGuestRunning(allStageDirs())) {
                    int cleared = clearGuestMarkers(allStageDirs());
                    hideFuncBar(pbReturn, tvReturnProgress);
                    if (cleared > 0) appendLog("Already in One UI — no guest is actually running. Cleared " + cleared + " stale guest-running marker(s); nothing was restored (no host services were touched).");
                    else appendLog("Already in One UI — no guest is running, nothing to restore.");
                    setLogStatus("One UI active");
                    return;
                }
                String stageScript = STAGE_DIR + "/return_to_oneui.sh";
                String cmd = "stageScript=" + STAGE_DIR + "/return_to_oneui.sh; " +
                             "chmod 755 $stageScript; " +
                             "BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox); " +
                             // 5.9.11: bounded busybox search (see bootGsi).
                             "[ -x \"$BB\" ] || BB=$(find /data/adb /system/bin /system/xbin /vendor/bin -maxdepth 3 -name busybox 2>/dev/null | head -n 1); " +
                             "if [ -n \"$BB\" ] && [ -x \"$BB\" ]; then " +
                             "  $BB setsid /system/bin/sh $stageScript </dev/null >" + STAGE_DIR + "/restore_app.log 2>&1 & " +
                             "else " +
                             "  nohup /system/bin/sh $stageScript </dev/null >" + STAGE_DIR + "/restore_app.log 2>&1 & " +
                             "fi";
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd});
                p.waitFor();
                appendLog("One UI restore triggered successfully.");
                // 5.9.11: stream the return log until RETURN_OK (or a
                // 120s cap) instead of leaving the user guessing.
                // 5.9.16: returningSlot (see its declaration) lets
                // the poller record this slot's outcome on RETURN_OK.
                returningSlot = selectedSlot;
                streamReturnProgress(STAGE_DIR + "/restore_app.log", pbReturn, tvReturnProgress, false);
            } catch (Exception e) {
                appendLog("Restore error: " + e.getMessage());
                setLogStatus("Error");
            }
        });
    }

    private void backupLauncher() {
        // 5.9.11: own colorful bar (launcher backup/restore share one).
        runBarTask(pbLauncher, tvLauncherProgress, "Backing up home layout…", () -> {
            setLogStatus("Backing up…");
            appendLog("\nBacking up One UI Home Screen database...");
            try {
                // 5.9.6: the old code logged success unconditionally even
                // when the copy copied nothing (e.g. no launcher database
                // found). Report success only when files actually landed.
                String cmd = "mkdir -p /data/local/tmp/lineage_backups && "
                        + "cp -a /data/user/0/com.sec.android.app.launcher/databases/* /data/local/tmp/lineage_backups/ 2>/dev/null; "
                        + "N=$(ls /data/local/tmp/lineage_backups/ 2>/dev/null | wc -l); "
                        + "if [ \"$N\" -gt 0 ]; then echo \"LAUNCHER_BACKUP_OK $N\"; else echo 'LAUNCHER_BACKUP_FAIL'; fi";
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd});
                BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                boolean ok = false;
                while ((line = reader.readLine()) != null) {
                    if (line.contains("LAUNCHER_BACKUP_OK")) ok = true;
                    appendLog("  " + line);
                }
                p.waitFor();
                if (ok) appendLog("✓ Home screen database successfully snapshotted!");
                else appendLog("✗ Home screen backup failed: no launcher database files were copied (is the Samsung launcher installed under com.sec.android.app.launcher?).");
                setLogStatus(ok ? "Idle" : "Error");
            } catch (Exception e) {
                appendLog("Backup failed: " + e.getMessage());
                setLogStatus("Error");
            }
        });
    }

    private void restoreLauncher() {
        // 5.9.11: own colorful bar (launcher backup/restore share one).
        runBarTask(pbLauncher, tvLauncherProgress, "Restoring home layout…", () -> {
            setLogStatus("Restoring…");
            appendLog("\nRestoring One UI Home Screen layout...");
            try {
                // 5.9.6: same honesty fix as backup — report success only
                // when the restore chain actually ran (and distinguish an
                // empty backup dir from a missing one).
                String cmd = "if [ -d /data/local/tmp/lineage_backups ] && [ -n \"$(ls /data/local/tmp/lineage_backups/ 2>/dev/null)\" ]; then " +
                             "LAUNCHER_DATA=/data/user/0/com.sec.android.app.launcher; " +
                             "L_UID=$(stat -c %u $LAUNCHER_DATA 2>/dev/null || echo 10160); " +
                             "L_GID=$(stat -c %g $LAUNCHER_DATA 2>/dev/null || echo 10160); " +
                             "cp -a /data/local/tmp/lineage_backups/* $LAUNCHER_DATA/databases/ && " +
                             "chown -R ${L_UID}:${L_GID} $LAUNCHER_DATA/databases && " +
                             "chmod 771 $LAUNCHER_DATA/databases && " +
                             "chmod 660 $LAUNCHER_DATA/databases/* && " +
                             "am force-stop com.sec.android.app.launcher && " +
                             "am start -a android.intent.action.MAIN -c android.intent.category.HOME && " +
                             "echo \"LAUNCHER_RESTORE_OK ${L_UID}\" || echo 'LAUNCHER_RESTORE_FAIL'; else echo 'LAUNCHER_RESTORE_NONE'; fi";
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd});
                BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                boolean ok = false, none = false;
                while ((line = reader.readLine()) != null) {
                    if (line.contains("LAUNCHER_RESTORE_OK")) ok = true;
                    if (line.contains("LAUNCHER_RESTORE_NONE")) none = true;
                    appendLog("  " + line);
                }
                p.waitFor();
                if (ok) appendLog("✓ Home screen layout restored.");
                else if (none) appendLog("✗ No home screen backup found — back up first.");
                else appendLog("✗ Home screen restore failed (the copy or the launcher restart failed).");
                setLogStatus(ok ? "Idle" : "Error");
            } catch (Exception e) {
                appendLog("Restore failed: " + e.getMessage());
                setLogStatus("Error");
            }
        });
    }

    // 5.9.5-APP-START
    private String prefSlot(String prefix, String slot) {
        try {
            return getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(prefix + slot, "");
        } catch (Exception ignored) { return ""; }
    }
    private boolean fixForSlot(String prefix, String slot) {
        try {
            return getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getBoolean(prefix + slot, false);
        } catch (Exception ignored) { return false; }
    }
    private boolean shareForSlot(String slot) { return fixForSlot(PREF_SHARE_PREFIX, slot); }
    private boolean guestRootForSlot(String slot) { return fixForSlot(PREF_GUEST_ROOT_PREFIX, slot); }
    private String densityForSlot(String slot) {
        String d = prefSlot(PREF_DENSITY_PREFIX, slot);
        return d == null ? "" : d;
    }
    private void saveSlotBool(String prefix, String slot, boolean v) {
        try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putBoolean(prefix + slot, v).apply(); } catch (Exception ignored) {}
    }
    private void saveSlotString(String prefix, String slot, String v) {
        try {
            android.content.SharedPreferences.Editor e = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit();
            if (v == null || v.isEmpty()) e.remove(prefix + slot); else e.putString(prefix + slot, v);
            e.apply();
        } catch (Exception ignored) {}
    }

    private void setup595Views() {
        tvBatteryStatus = findViewById(R.id.tv_battery_status);
        cbBatteryGuard = findViewById(R.id.cb_battery_guard);
        tvSlotBootInfo = findViewById(R.id.tv_slot_boot_info);
        cbAutoboot = findViewById(R.id.cb_autoboot);
        btnReturnReboot = findViewById(R.id.btn_return_reboot);
        tvSnapshotList = findViewById(R.id.tv_snapshot_list);
        btnSnapshotRefresh = findViewById(R.id.btn_snapshot_refresh);
        btnSnapshotCreate = findViewById(R.id.btn_snapshot_create);
        btnSnapshotRollback = findViewById(R.id.btn_snapshot_rollback);
        btnBackupMulti = findViewById(R.id.btn_backup_multi);
        btnVerifyBackup = findViewById(R.id.btn_verify_backup);
        cbGuestRoot = findViewById(R.id.cb_guest_root);
        tvGuestRootState = findViewById(R.id.tv_guest_root_state);
        tvFrameworkVersion = findViewById(R.id.tv_framework_version);
        spDensity = findViewById(R.id.sp_density);
        etDensityCustom = findViewById(R.id.et_density_custom);
        cbShareFolder = findViewById(R.id.cb_share_folder);
        tvGuestFixesStatus = findViewById(R.id.tv_guest_fixes_status);
        btnPreflight = findViewById(R.id.btn_preflight);
        tvPreflightResult = findViewById(R.id.tv_preflight_result);
        btnPauseDownload = findViewById(R.id.btn_pause_download);
        btnResumeDownload = findViewById(R.id.btn_resume_download);
        cbLogAutoscroll = findViewById(R.id.cb_log_autoscroll);
        btnViewLogcat = findViewById(R.id.btn_view_logcat);
        // 5.9.5-INT-START
        btnShareLog = findViewById(R.id.btn_share_log);
        btnExperimental = findViewById(R.id.btn_experimental);
        vSlotColor = findViewById(R.id.v_slot_color);
        btnSlotColor = findViewById(R.id.btn_slot_color);
        tvInfoStorage = findViewById(R.id.tv_info_storage);
        // 5.9.5-INT-END
        if (cbBatteryGuard != null) {
            cbBatteryGuard.setChecked(batteryGuardEnabled);
            cbBatteryGuard.setOnCheckedChangeListener((v, c) -> {
                batteryGuardEnabled = c;
                try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putBoolean(PREF_BATTERY_GUARD, c).apply(); } catch (Exception ignored) {}
            });
        }
        if (cbLogAutoscroll != null) {
            cbLogAutoscroll.setChecked(logAutoScroll);
            cbLogAutoscroll.setOnCheckedChangeListener((v, c) -> {
                logAutoScroll = c;
                // 5.9.17: re-enabling auto-scroll unpins the log, so
                // following resumes immediately instead of staying
                // parked above the tail from an earlier read-back.
                if (c) logUserPinned = false;
                try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putBoolean(PREF_LOG_AUTOSCROLL, c).apply(); } catch (Exception ignored) {}
            });
        }
        if (cbAutoboot != null) {
            boolean ab = false;
            try { ab = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getBoolean(PREF_AUTOBOOT, false); } catch (Exception ignored) {}
            cbAutoboot.setChecked(ab);
            cbAutoboot.setOnCheckedChangeListener((v, c) -> {
                try {
                    android.content.SharedPreferences.Editor e = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit();
                    e.putBoolean(PREF_AUTOBOOT, c);
                    if (c) e.putString(PREF_AUTOBOOT_SLOT, selectedSlot);
                    e.apply();
                } catch (Exception ignored) {}
                appendLog(c ? "Auto-boot ON for slot '" + selectedSlot + "' (asks for confirmation on launch, needs root; never silent)."
                        : "Auto-boot OFF.");
            });
        }
        // 5.9.11: wipe-after-install toggle (hero section). Persisted
        // immediately on tap; the install flow reads the field.
        if (cbWipeAfterInstall != null) {
            cbWipeAfterInstall.setChecked(wipeAfterInstall);
            cbWipeAfterInstall.setOnCheckedChangeListener((v, c) -> {
                wipeAfterInstall = c;
                try { getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putBoolean(PREF_WIPE_AFTER_INSTALL, c).apply(); } catch (Exception ignored) {}
                appendLog(c ? "Wipe-after-install ON: guest userdata will be wiped right after the next good install (system.raw kept)."
                        : "Wipe-after-install OFF.");
            });
        }
        if (btnReturnReboot != null) btnReturnReboot.setOnClickListener(v -> returnToOneUIReboot());
        if (btnSnapshotRefresh != null) btnSnapshotRefresh.setOnClickListener(v -> listSnapshots());
        if (btnSnapshotCreate != null) btnSnapshotCreate.setOnClickListener(v -> createSnapshot());
        if (btnSnapshotRollback != null) btnSnapshotRollback.setOnClickListener(v -> rollbackSnapshot());
        if (btnBackupMulti != null) btnBackupMulti.setOnClickListener(v -> createMultiBackup());
        if (btnVerifyBackup != null) btnVerifyBackup.setOnClickListener(v -> verifyBackup());
        if (btnPreflight != null) btnPreflight.setOnClickListener(v -> runPreflight());
        if (btnViewLogcat != null) btnViewLogcat.setOnClickListener(v -> saveLogcatAndShow());
        // 5.9.5-INT-START
        if (btnShareLog != null) btnShareLog.setOnClickListener(v -> shareLog());
        if (btnExperimental != null) btnExperimental.setOnClickListener(v -> showExperimentalMenu());
        if (btnSlotColor != null) btnSlotColor.setOnClickListener(v -> promptSlotColor());
        // 5.9.5-INT-END
        if (btnPauseDownload != null) btnPauseDownload.setOnClickListener(v -> {
            // 5.9.6: Pause only means something mid-download. 5.9.5 set
            // the flag unconditionally, so a stray tap poisoned the NEXT
            // download (it paused on its first chunk).
            if (!downloading) {
                appendLog("No download in progress to pause.");
                return;
            }
            downloadPauseRequested = true;
            appendLog("Download pause requested — the current chunk will finish, then the partial file is kept for Resume.");
        });
        if (btnResumeDownload != null) btnResumeDownload.setOnClickListener(v -> {
            // 5.9.6: the button is hidden unless a real interrupted
            // download exists (see updateDownloadButtons); this check
            // is only a backstop and should never be reachable.
            if (lastDownloadUrl == null) {
                appendLog("ERROR: No download in progress to resume. Start a download first, then Pause/Resume it.");
                updateDownloadButtons();
                return;
            }
            corruptDownloadRetried = false;
            startNetworkDownload(lastDownloadUrl, lastDownloadExpected, lastDownloadLabel, true);
        });
        if (spDensity != null) {
            ArrayAdapter<String> da = new ArrayAdapter<>(this, R.layout.spinner_item,
                    new String[]{"Default (no override)", "320", "360", "400", "420", "480", "Custom"});
            da.setDropDownViewResource(R.layout.spinner_dropdown_item);
            densitySpinnerInit = false;
            spDensity.setAdapter(da);
            spDensity.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
                public void onItemSelected(AdapterView<?> parent, View view, int pos, long id) {
                    if (!densitySpinnerInit) return;
                    String val = "";
                    if (pos == 1) val = "320";
                    else if (pos == 2) val = "360";
                    else if (pos == 3) val = "400";
                    else if (pos == 4) val = "420";
                    else if (pos == 5) val = "480";
                    else if (pos == 6) {
                        if (etDensityCustom != null) val = etDensityCustom.getText().toString().trim();
                        if (!val.matches("[0-9]+")) { appendLog("ERROR: Custom density must be a number (e.g. 440)."); return; }
                    }
                    saveSlotString(PREF_DENSITY_PREFIX, selectedSlot, val);
                    writeGsiFlagsFile();
                    appendLog("Density for slot '" + selectedSlot + "': " + (val.isEmpty() ? "default" : val + " dpi") + " (passed as DENSITY_DPI at boot).");
                }
                public void onNothingSelected(AdapterView<?> parent) {}
            });
            densitySpinnerInit = true;
        }
        if (etDensityCustom != null) etDensityCustom.setOnFocusChangeListener((v, hasFocus) -> {
            if (!hasFocus && spDensity != null && spDensity.getSelectedItemPosition() == 6) {
                String val = etDensityCustom.getText().toString().trim();
                if (val.matches("[0-9]+")) {
                    saveSlotString(PREF_DENSITY_PREFIX, selectedSlot, val);
                    writeGsiFlagsFile();
                }
            }
        });
        if (cbShareFolder != null) cbShareFolder.setOnCheckedChangeListener((v, c) -> {
            saveSlotBool(PREF_SHARE_PREFIX, selectedSlot, c);
            writeGsiFlagsFile();
            updateGuestFixesStatus();
        });
        // 5.9.6: the IMS / dev-options / codec toggles are removed (no
        // script ever read those flags). Samsung's text service is kept
        // alive unconditionally by switch_to_gsi.sh's keepalive.
        if (cbGuestRoot != null) cbGuestRoot.setOnCheckedChangeListener((v, c) -> {
            if (updatingGuestRootUi) return;
            setGuestRoot(c);
        });
        refresh595SlotControls();
        refreshGuestRootState();
        updateGuestFixesStatus();
    }

    private void refresh595SlotControls() {
        try {
            String slot = selectedSlot;
            if (cbShareFolder != null) cbShareFolder.setChecked(shareForSlot(slot));
            if (spDensity != null) {
                String d = densityForSlot(slot);
                int pos = 0;
                if ("320".equals(d)) pos = 1;
                else if ("360".equals(d)) pos = 2;
                else if ("400".equals(d)) pos = 3;
                else if ("420".equals(d)) pos = 4;
                else if ("480".equals(d)) pos = 5;
                else if (!d.isEmpty()) { pos = 6; if (etDensityCustom != null) etDensityCustom.setText(d); }
                densitySpinnerInit = false;
                spDensity.setSelection(pos, false);
                densitySpinnerInit = true;
            }
            updateGuestFixesStatus();
        } catch (Exception ignored) {}
    }

    private void updateGuestFixesStatus() {
        if (tvGuestFixesStatus == null) return;
        String d = densityForSlot(selectedSlot);
        String s = "Guest options for slot '" + selectedSlot + "': shared folder " + (shareForSlot(selectedSlot) ? "ON" : "off")
                + ", display density " + (d.isEmpty() ? "default" : d + " dpi")
                + ", guest root " + (guestRootForSlot(selectedSlot) ? "ON" : "OFF")
                + ". These are saved here and passed to the boot scripts at the next boot; Samsung's text service is kept alive during every guest session regardless.";
        tvGuestFixesStatus.setText(s);
    }

    private void refreshBattery() {
        try {
            BatteryManager bm = (BatteryManager) getSystemService(Context.BATTERY_SERVICE);
            if (bm != null) {
                int cap = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
                if (cap >= 0) batteryPct = cap;
            }
            android.content.Intent batt = registerReceiver(null, new IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED));
            if (batt != null) {
                int level = batt.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
                int scale = batt.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
                if (level >= 0 && scale > 0) batteryPct = (level * 100) / scale;
                int plugged = batt.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1);
                batteryCharging = plugged == BatteryManager.BATTERY_PLUGGED_AC
                        || plugged == BatteryManager.BATTERY_PLUGGED_USB
                        || plugged == BatteryManager.BATTERY_PLUGGED_WIRELESS;
            }
        } catch (Exception ignored) {}
        final String text = batteryPct >= 0
                ? "Battery: " + batteryPct + "%" + (batteryCharging ? " (charging)" : " (not charging)")
                        + (batteryGuardEnabled ? " • guard ON" : " • guard OFF")
                : "Battery: unknown (BatteryManager unavailable)";
        mainHandler.post(() -> { if (tvBatteryStatus != null) tvBatteryStatus.setText(text); });
    }

    // 5.9.7: a plugged-in phone cannot die mid-install, so the
    // corruption risk this guard exists for is gone while charging:
    // at <=10% AND charging, warn in the log and proceed on ONE tap.
    // At <=10% and NOT charging, the block stays, but the override is
    // now session-persistent instead of one-shot, so it does not recur
    // on every install. Warn at <=20% as before.
    private boolean batteryGuardAllows(final String op, final Runnable retry) {
        refreshBattery();
        if (!batteryGuardEnabled || batteryPct < 0) return true;
        if (batteryPct <= 10 && ("install".equals(op) || "backup".equals(op) || "boot".equals(op) || "snapshot".equals(op))) {
            if (batteryCharging) {
                appendLog("Battery guard: " + batteryPct + "% but charging — proceeding with " + op + " (a plugged-in phone cannot die mid-operation).");
                return true;
            }
            if (batteryOverrideSession) { appendLog("Battery guard overridden for this session for " + op + " at " + batteryPct + "%."); return true; }
            // 5.9.16: the Install tap that produced this dialog already
            // stamped lastInstallTapMs, so the Override retry (retry.run()
            // below) would be swallowed by installGsi's 500 ms debounce
            // whenever the user tapped Override quickly — dialog gone,
            // override saved, install never run. Clear the stamp so the
            // retry is a real tap, not a debounced-away one.
            if ("install".equals(op)) lastInstallTapMs = 0;
            new AlertDialog.Builder(this)
                .setTitle("Battery too low for " + op)
                .setMessage("Battery is " + batteryPct + "% and not charging. Install / backup / slot-switch / snapshot is blocked at 10% or below to avoid corrupting the image if the phone dies. Plug in, or tap Override for this session to proceed for the rest of this session.")
                .setPositiveButton("Override for this session", (d, w) -> { batteryOverrideSession = true; retry.run(); })
                .setNegativeButton("Cancel", null)
                .show();
            return false;
        }
        if (batteryPct <= 20) {
            appendLog("Battery warning: " + batteryPct + "% before " + op + " (guard warns at 20%, blocks at 10% when not charging).");
        }
        return true;
    }

    private void maybePromptAutoboot() {
        if (autobootPrompted) return;
        boolean enabled = false;
        String slot = null;
        try {
            android.content.SharedPreferences pr = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
            enabled = pr.getBoolean(PREF_AUTOBOOT, false);
            slot = pr.getString(PREF_AUTOBOOT_SLOT, null);
        } catch (Exception ignored) {}
        if (!enabled || slot == null || slot.isEmpty()) return;
        autobootPrompted = true;
        final String target = slot;
        refreshBattery();
        new AlertDialog.Builder(this)
            .setTitle("Auto-boot slot '" + target + "'?")
            .setMessage("Auto-boot is ON for slot '" + target + "' (battery " + (batteryPct >= 0 ? batteryPct + "%" : "unknown") + "). Boot it now? This is the only auto-boot prompt on this launch — it never boots silently and never boots without root.")
            .setPositiveButton("Boot now", (d, w) -> {
                selectedSlot = target;
                saveGsiPrefs();
                refreshSlots();
                bootGsi();
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void refreshBootMenuInfo(String sizeText, String bootsText, String noteText) {
        if (tvSlotBootInfo == null) return;
        StringBuilder sb = new StringBuilder();
        sb.append("Boot menu (in-app only — not a bootloader menu): ");
        if (slotValues != null && !slotValues.isEmpty()) {
            sb.append("slots: ");
            for (int i = 0; i < slotValues.size(); i++) {
                if (i > 0) sb.append(", ");
                sb.append(slotValues.get(i));
                try {
                    String last = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(PREF_LAST_BOOT, null);
                    if (slotValues.get(i).equals(last)) sb.append(" (last booted)");
                } catch (Exception ignored) {}
            }
            sb.append(". ");
        }
        sb.append("Selected: '").append(selectedSlot).append("'.");
        if (sizeText != null) sb.append(" ").append(sizeText).append(".");
        if (bootsText != null) sb.append(" ").append(bootsText).append(".");
        if (noteText != null) sb.append(" ").append(noteText).append(".");
        tvSlotBootInfo.setText(sb.toString());
    }

    private void returnToOneUIReboot() {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to restore One UI!");
            return;
        }
        new AlertDialog.Builder(this)
            .setTitle("Return to One UI + reboot?")
            .setMessage("This runs return_to_oneui.sh --reboot (panic reboot). The guest is stopped, One UI is restored, then the phone reboots. If no guest is actually running, it just clears any stale state and reboots. Are you sure?")
            .setPositiveButton("Reboot", (d, w) -> {
                // 5.9.11: instant bar on the tap itself (this lambda
                // runs on the main thread), then the work on executor.
                showFuncBar(pbReboot, tvRebootProgress, "Returning to One UI + reboot…");
                executor.execute(() -> {
                    try {
                        // 5.9.13 LIGHT PATH (same rule as Return): if
                        // no guest is actually running, skip the full
                        // restore script and just reboot — the reboot
                        // is the point, and restoring an already
                        // running One UI is pointless churn.
                        if (!anyGuestRunning(allStageDirs())) {
                            int cleared = clearGuestMarkers(allStageDirs());
                            String rebootCmd = "(reboot 2>/dev/null || setprop sys.powerctl reboot) &";
                            Runtime.getRuntime().exec(new String[]{suBinary, "-c", rebootCmd}).waitFor();
                            appendLog("Already in One UI — no guest was running" + (cleared > 0 ? ("; cleared " + cleared + " stale guest-running marker(s)") : "") + ". Rebooting directly (no restore script needed).");
                            hideFuncBar(pbReboot, tvRebootProgress);
                            return;
                        }
                        String cmd = "chmod 755 " + STAGE_DIR + "/return_to_oneui.sh; "
                                + "/system/bin/sh " + STAGE_DIR + "/return_to_oneui.sh --reboot </dev/null >" + STAGE_DIR + "/restore_app.log 2>&1 &";
                        Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd}).waitFor();
                        appendLog("One UI restore + reboot triggered (return_to_oneui.sh --reboot).");
                        // 5.9.11: stream the return steps until the
                        // reboot kills the app (expected end).
                        // 5.9.16: returningSlot set as in Return; in
                        // practice the reboot usually kills the poll
                        // before RETURN_OK is observed, so this
                        // variant's outcome is often simply the
                        // previous recorded one — stated, not hidden.
                        returningSlot = selectedSlot;
                        streamReturnProgress(STAGE_DIR + "/restore_app.log", pbReboot, tvRebootProgress, true);
                    } catch (Exception e) {
                        appendLog("Reboot restore error: " + e.getMessage());
                        hideFuncBar(pbReboot, tvRebootProgress);
                    }
                });
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private List<String> runScriptLines(String script, String... args) {
        List<String> out = new ArrayList<>();
        try {
            StringBuilder cmd = new StringBuilder(STAGE_DIR + "/" + script);
            for (String a : args) {
                String safe = a == null ? "" : a.replace("'", "").replace(";", "").replace(" ", "_");
                cmd.append(" ").append(safe);
            }
            ProcessBuilder pb = new ProcessBuilder(suBinary, "-c", cmd.toString());
            pb.redirectErrorStream(true);
            Process p = pb.start();
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = r.readLine()) != null) out.add(line);
            p.waitFor();
        } catch (Exception e) {
            out.add("SCRIPT_ERROR " + e.getMessage());
        }
        return out;
    }

    private void promptScriptName(String title, String hint, SlotNameAction action) {
        final EditText input = new EditText(this);
        input.setHint(hint);
        new AlertDialog.Builder(this)
            .setTitle(title)
            .setView(input)
            .setPositiveButton("OK", (d, w) -> action.run(input.getText().toString().trim()))
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void listSnapshots() {
        if (!isRootGranted) { appendLog("ERROR: Root privilege required to list snapshots!"); return; }
        final String slot = selectedSlot;
        final String dir = currentSlotDir();
        // 5.9.11: own colorful bar (snapshot ops share one bar).
        runBarTask(pbSnapshot, tvSnapshotProgress, "Listing snapshots…", () -> {
            List<String> names = new ArrayList<>();
            List<String> backs = new ArrayList<>();
            try {
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "ls -1 " + dir + "/snapshots 2>/dev/null; echo ---BACKUPS---; ls -1 " + dir + "/backups 2>/dev/null; ls -1 " + STAGE_DIR + "/backups 2>/dev/null"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                boolean inBack = false;
                while ((line = r.readLine()) != null) {
                    line = line.trim();
                    if ("---BACKUPS---".equals(line)) { inBack = true; continue; }
                    if (line.isEmpty()) continue;
                    if (inBack) { if (!backs.contains(line)) backs.add(line); }
                    else names.add(line);
                }
                p.waitFor();
            } catch (Exception ignored) {}
            final String snapText = "Snapshots for slot '" + slot + "': " + (names.isEmpty() ? "none found" : android.text.TextUtils.join(", ", names))
                    + " • Backups: " + (backs.isEmpty() ? "none found" : android.text.TextUtils.join(", ", backs));
            mainHandler.post(() -> { if (tvSnapshotList != null) tvSnapshotList.setText(snapText); });
            appendLog(snapText + " (snapshot_slot.sh / backup_slot.sh are bundled with the app).");
        });
    }

    private void createSnapshot() {
        if (!isRootGranted) { appendLog("ERROR: Root privilege required to create a snapshot!"); return; }
        if (!batteryGuardAllows("snapshot", () -> createSnapshot())) return;
        final String slot = selectedSlot;
        final String dir = currentSlotDir();
        promptScriptName("Create snapshot for slot '" + slot + "'", "snapshot name (letters, digits, -, _)", name -> {
            if (!isValidSlotName(name)) { appendLog("ERROR: Invalid snapshot name '" + name + "'."); return; }
            // 5.9.11: own colorful bar (snapshot ops share one bar).
            runBarTask(pbSnapshot, tvSnapshotProgress, "Creating snapshot…", () -> {
                List<String> out = runScriptLines("snapshot_slot.sh", dir, name);
                String first = out.isEmpty() ? "" : out.get(0);
                if (first.startsWith("SNAPSHOT_OK")) appendLog("Snapshot OK for slot '" + slot + "': " + first);
                else appendLog("Snapshot FAILED for slot '" + slot + "' (snapshot_slot.sh output: " + android.text.TextUtils.join(" | ", out) + "). If the output is empty, the script may be missing from staging — tap Re-check root and status to re-extract the app's scripts.");
                listSnapshots();
            });
        });
    }

    private void rollbackSnapshot() {
        if (!isRootGranted) { appendLog("ERROR: Root privilege required to roll back!"); return; }
        if (!batteryGuardAllows("snapshot", () -> rollbackSnapshot())) return;
        final String slot = selectedSlot;
        final String dir = currentSlotDir();
        promptScriptName("Rollback slot '" + slot + "' to snapshot", "snapshot name", name -> {
            if (!isValidSlotName(name)) { appendLog("ERROR: Invalid snapshot name '" + name + "'."); return; }
            new AlertDialog.Builder(this)
                .setTitle("Rollback slot '" + slot + "'?")
                .setMessage("This replaces the slot's current state with snapshot '" + name + "'. Unsaved guest changes will be lost. This cannot be undone.")
                .setPositiveButton("Rollback", (d, w) -> runBarTask(pbSnapshot, tvSnapshotProgress, "Rolling back snapshot…", () -> {
                    List<String> out = runScriptLines("rollback_slot.sh", dir, name);
                    String first = out.isEmpty() ? "" : out.get(0);
                    if (first.startsWith("ROLLBACK_OK")) appendLog("Rollback OK: slot '" + slot + "' -> snapshot '" + name + "'.");
                    else appendLog("Rollback FAILED for slot '" + slot + "' (rollback_slot.sh output: " + android.text.TextUtils.join(" | ", out) + ").");
                    checkImageStatus();
                }))
                .setNegativeButton("Cancel", null)
                .show();
        });
    }

    private void createMultiBackup() {
        if (!isRootGranted) { appendLog("ERROR: Root privilege required to back up!"); return; }
        if (!batteryGuardAllows("backup", () -> createMultiBackup())) return;
        final String slot = selectedSlot;
        final String dir = currentSlotDir();
        promptScriptName("Create multi-gen backup for slot '" + slot + "'", "backup name (existing names are never overwritten)", name -> {
            if (!isValidSlotName(name)) { appendLog("ERROR: Invalid backup name '" + name + "'."); return; }
            executor.execute(() -> {
                List<String> out = runScriptLines("backup_slot.sh", dir, name);
                String first = out.isEmpty() ? "" : out.get(0);
                if (first.startsWith("BACKUP_OK")) {
                    String[] parts = first.split(" ");
                    appendLog("Backup OK for slot '" + slot + "': " + first + (parts.length >= 3 ? " (sha256 " + parts[2] + ")" : ""));
                } else {
                    appendLog("Backup FAILED for slot '" + slot + "' (backup_slot.sh output: " + android.text.TextUtils.join(" | ", out) + "). Note: backup_slot.sh never overwrites an existing backup name.");
                }
                listSnapshots();
            });
        });
    }

    private void verifyBackup() {
        if (!isRootGranted) { appendLog("ERROR: Root privilege required to verify a backup!"); return; }
        promptScriptName("Verify backup", "backup directory path (or name under this slot's backups/)", input -> {
            if (input == null || input.isEmpty()) { appendLog("ERROR: No backup path entered."); return; }
            final String dirArg = input.contains("/") ? input : currentSlotDir() + "/backups/" + input;
            // 5.9.11: own colorful bar (snapshot ops share one bar).
            runBarTask(pbSnapshot, tvSnapshotProgress, "Verifying backup…", () -> {
                List<String> out = runScriptLines("verify_backup.sh", dirArg);
                // 5.9.16: VERIFY_STRUCTURAL is a distinct verdict,
                // never OK — the script prints it when sha/size/
                // manifest + magic pass but no mount check ever ran.
                // Scan all lines, not just the first: the script's
                // verdict is its last verdict line.
                String verdict = "";
                for (String l : out) {
                    if (l.startsWith("VERIFY_OK") || l.startsWith("VERIFY_FAIL") || l.startsWith("VERIFY_STRUCTURAL")) verdict = l;
                }
                if (verdict.startsWith("VERIFY_OK")) appendLog("Backup verify OK (mount-checked): " + dirArg);
                else if (verdict.startsWith("VERIFY_STRUCTURAL")) appendLog("Backup verify STRUCTURAL ONLY (not a full OK): " + verdict + " — for " + dirArg + ". The backup's hashes and filesystem magic check out, but it was never loop-mounted and verified, so do not treat this as a proven-good restore source.");
                else if (verdict.startsWith("VERIFY_FAIL")) appendLog("Backup verify FAILED: " + verdict);
                else appendLog("Backup verify result unknown (verify_backup.sh output: " + android.text.TextUtils.join(" | ", out) + ").");
            });
        });
    }

    private void setGuestRoot(final boolean on) {
        if (!isRootGranted) {
            appendLog("ERROR: Root privilege required to change guest root!");
            updatingGuestRootUi = true;
            if (cbGuestRoot != null) cbGuestRoot.setChecked(!on);
            updatingGuestRootUi = false;
            return;
        }
        final String slot = selectedSlot;
        final String dir = currentSlotDir();
        executor.execute(() -> {
            List<String> out = runScriptLines("guest_root.sh", dir, on ? "on" : "off");
            String first = out.isEmpty() ? "" : out.get(0);
            final String want = on ? "GUEST_ROOT_ON" : "GUEST_ROOT_OFF";
            if (first.startsWith(want)) {
                saveSlotBool(PREF_GUEST_ROOT_PREFIX, slot, on);
                writeGsiFlagsFile();
                appendLog("Guest root " + (on ? "ON" : "OFF") + " for slot '" + slot + "' (" + first + ").");
                mainHandler.post(() -> { if (tvGuestRootState != null) tvGuestRootState.setText("Guest root: " + (on ? "ON" : "OFF") + " (script-reported)"); });
            } else if (first.startsWith("GUEST_ROOT_UNSUPPORTED")) {
                appendLog("Guest root unsupported for slot '" + slot + "': " + first + " — toggle reverted.");
                mainHandler.post(() -> {
                    updatingGuestRootUi = true;
                    if (cbGuestRoot != null) cbGuestRoot.setChecked(!on);
                    updatingGuestRootUi = false;
                    if (tvGuestRootState != null) tvGuestRootState.setText("Guest root: unsupported (" + first + ")");
                });
            } else {
                appendLog("Guest root change result unknown (guest_root.sh output: " + android.text.TextUtils.join(" | ", out) + "). Saved pref kept as before; if the output is empty, the script may be missing from staging — tap Re-check root and status to re-extract the app's scripts.");
                mainHandler.post(() -> {
                    updatingGuestRootUi = true;
                    if (cbGuestRoot != null) cbGuestRoot.setChecked(guestRootForSlot(slot));
                    updatingGuestRootUi = false;
                });
            }
        });
    }

    private void refreshGuestRootState() {
        final String slot = selectedSlot;
        final boolean pref = guestRootForSlot(slot);
        mainHandler.post(() -> {
            updatingGuestRootUi = true;
            if (cbGuestRoot != null) cbGuestRoot.setChecked(pref);
            updatingGuestRootUi = false;
            if (tvGuestRootState != null) tvGuestRootState.setText("Guest root: " + (pref ? "ON" : "OFF") + " (saved pref; script-reported state updates when the toggle is used)");
        });
    }

    private String lastGatedFramework = null;
    private String lastFitWarnedFor = null;
    private void detectFrameworkVersion() {
        if (!isRootGranted) {
            mainHandler.post(() -> { if (tvFrameworkVersion != null) tvFrameworkVersion.setText("Framework: unknown (root required to read guest build.prop)"); });
            return;
        }
        final String rootfs = currentRootfs();
        executor.execute(() -> {
            String sdk = null, rel = null, lineage = null;
            try {
                // 5.9.16: KEYED grep, not positional. The old code
                // ran three greps and assigned their outputs by line
                // index (sdk/rel/lineage) — but a grep that matches
                // nothing prints nothing, so one missing key shifted
                // every later field into the wrong slot (a guest with
                // no ro.lineage.version read its release as its
                // lineage version). Now the shell emits a TAGGED
                // line for every key even when the value is empty
                // (SDK:/REL:/LIN:), and Java assigns by tag, so a
                // missing key can never shift another field. Total
                // failure (no build.prop at all) still yields three
                // empty tags, which fall through to "unknown" below
                // exactly as before. Equivalents: release falls back
                // to release_or_codename, lineage to
                // ro.lineage.build.version, only when the primary
                // key is empty.
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                    "BP=\"" + rootfs + "/system/build.prop\"; "
                    + "SDK=$(grep -m1 '^ro.build.version.sdk=' \"$BP\" 2>/dev/null | cut -d= -f2-); echo \"SDK:$SDK\"; "
                    + "REL=$(grep -m1 '^ro.build.version.release=' \"$BP\" 2>/dev/null | cut -d= -f2-); [ -z \"$REL\" ] && REL=$(grep -m1 '^ro.build.version.release_or_codename=' \"$BP\" 2>/dev/null | cut -d= -f2-); echo \"REL:$REL\"; "
                    + "LIN=$(grep -m1 '^ro.lineage.version=' \"$BP\" 2>/dev/null | cut -d= -f2-); [ -z \"$LIN\" ] && LIN=$(grep -m1 '^ro.lineage.build.version=' \"$BP\" 2>/dev/null | cut -d= -f2-); echo \"LIN:$LIN\""});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                while ((line = r.readLine()) != null) {
                    line = line.trim();
                    if (line.startsWith("SDK:")) sdk = line.substring(4);
                    else if (line.startsWith("REL:")) rel = line.substring(4);
                    else if (line.startsWith("LIN:")) lineage = line.substring(4);
                }
                p.waitFor();
            } catch (Exception ignored) {}
            final String fSdk = sdk, fRel = rel, fLineage = lineage;
            final boolean known = (fLineage != null && !fLineage.isEmpty()) || (fRel != null && !fRel.isEmpty());
            final boolean patched = fLineage != null && fLineage.contains("23.2");
            if (known) detectedFrameworkVersion = (fLineage != null && !fLineage.isEmpty()) ? fLineage : fRel;
            else detectedFrameworkVersion = "unknown";
            final String label;
            if (fLineage != null && !fLineage.isEmpty()) {
                label = "Framework: LineageOS " + fLineage + ((fRel != null && !fRel.isEmpty()) ? " / Android " + fRel : "");
            } else if (fRel != null && !fRel.isEmpty()) {
                label = "Framework: Android " + fRel + ((fSdk != null && !fSdk.isEmpty()) ? " (SDK " + fSdk + ")" : "") + " — not LineageOS 23.2";
            } else {
                label = "Framework: unknown (boot the slot to read its build.prop)";
            }
            detectedFrameworkLabel = label;
            // 5.9.16: pre-boot fit warning for a mounted guest whose
            // SDK is older than the host vendor SDK (the same
            // comparison install_image.sh prints as FIT_WARNING for
            // an install candidate). Logged once per detected
            // version so refreshSlotInfo's repeated detections do
            // not spam the log. A guest NEWER than the vendor gets
            // no warning (Treble rule: GSI >= vendor is the safe
            // direction).
            if (known && fSdk != null && !fSdk.isEmpty()) {
                try {
                    int guestSdk = Integer.parseInt(fSdk.trim());
                    int hostSdk = android.os.Build.VERSION.SDK_INT;
                    String fitKey = fSdk + "/" + hostSdk;
                    if (guestSdk < hostSdk && !fitKey.equals(lastFitWarnedFor)) {
                        lastFitWarnedFor = fitKey;
                        appendLog("⚠ Fit warning: this guest is older than your vendor (guest SDK " + guestSdk + (fRel != null && !fRel.isEmpty() ? " / Android " + fRel : "") + " vs host SDK " + hostSdk + ") — expect HAL trouble. This is the same skew the install fit check flags before install completes.");
                    }
                } catch (Exception ignored) {}
            }
            mainHandler.post(() -> {
                if (tvFrameworkVersion != null) tvFrameworkVersion.setText(label);
                if (known && !patched) {
                    if (!detectedFrameworkVersion.equals(lastGatedFramework)) {
                        lastGatedFramework = detectedFrameworkVersion;
                        appendLog("Framework gate: guest is NOT LineageOS 23.2 (" + label + ") — 23.2 patch toggles disabled; guest will boot unpatched. 23.2 jars are never silently applied to a non-23.2 guest.");
                    }
                    setPatchToggles(false, false, false);
                    if (cbPatchFramework != null) cbPatchFramework.setEnabled(false);
                    if (cbPatchPermission != null) cbPatchPermission.setEnabled(false);
                    if (cbPatchApexList != null) cbPatchApexList.setEnabled(false);
                } else if (known && patched) {
                    lastGatedFramework = detectedFrameworkVersion;
                    if (cbPatchFramework != null) cbPatchFramework.setEnabled(true);
                    if (cbPatchPermission != null) cbPatchPermission.setEnabled(true);
                    if (cbPatchApexList != null) cbPatchApexList.setEnabled(true);
                }
                writeGsiFlagsFile();
            });
        });
    }

    private void runPreflight() {
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED
                || checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            appendLog("Pre-flight needs Camera + Microphone permissions — requesting them now; tap Pre-flight again after granting.");
            requestPermissions(new String[]{Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO}, REQ_PROBE_PERMS);
            return;
        }
        mainHandler.post(() -> { if (tvPreflightResult != null) tvPreflightResult.setText("Pre-flight: running (mic 2s + camera0)…"); });
        // 5.9.11: own colorful bar.
        runBarTask(pbPreflight, tvPreflightProgress, "Pre-flight check…", () -> {
            StringBuilder report = new StringBuilder();
            List<String> host = runScriptLines("preflight_host.sh");
            String hfirst = host.isEmpty() ? "" : host.get(0);
            if (hfirst.startsWith("PREFLIGHT_OK") || hfirst.startsWith("PREFLIGHT_FAIL")) {
                report.append("host: ").append(hfirst).append("\n");
            } else {
                report.append("host: preflight_host.sh not present / produced no output (the host check script may be missing from staging)\n");
            }
            report.append(probeMicCamera());
            // Fallback note: the standalone probe-av app is NOT required —
            // the probe above is bundled in this app. Only mention it if the
            // bundled probe could not run at all.
            if (report.toString().contains("PROBE_UNAVAILABLE")) {
                try {
                    android.content.Intent li = getPackageManager().getLaunchIntentForPackage("com.test.avprobe");
                    if (li != null) {
                        startActivity(li);
                        report.append("probe-av app found; launched it as a fallback.\n");
                    } else {
                        report.append("probe-av app not installed (bundled probe is primary; no second install required).\n");
                    }
                } catch (Exception e) {
                    report.append("probe-av fallback unavailable: ").append(e.getMessage()).append("\n");
                }
            }
            final String result = report.toString();
            appendLog("Pre-flight result:\n" + result);
            mainHandler.post(() -> { if (tvPreflightResult != null) tvPreflightResult.setText(result); });
        });
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_PROBE_PERMS) {
            boolean ok = true;
            for (int g : grantResults) if (g != PackageManager.PERMISSION_GRANTED) ok = false;
            if (ok) runPreflight();
            else appendLog("Pre-flight cancelled: Camera / Microphone permission denied.");
        }
    }

    private String probeMicCamera() {
        StringBuilder sb = new StringBuilder();
        sb.append("--- MIC (2s) ---\n");
        try {
            int rate = 44100;
            int min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            AudioRecord rec = new AudioRecord(MediaRecorder.AudioSource.MIC, rate,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, Math.max(min, rate * 2));
            if (rec.getState() != AudioRecord.STATE_INITIALIZED) {
                sb.append("MIC FAIL: not initialized\n");
                rec.release();
            } else {
                rec.startRecording();
                short[] buf = new short[rate / 2];
                long sum = 0, peak = 0, frames = 0;
                long end = System.currentTimeMillis() + 2000;
                while (System.currentTimeMillis() < end) {
                    int n = rec.read(buf, 0, buf.length);
                    if (n > 0) {
                        for (int i = 0; i < n; i++) {
                            long v = Math.abs(buf[i]);
                            sum += (long) buf[i] * buf[i];
                            if (v > peak) peak = v;
                        }
                        frames += n;
                    }
                }
                try { rec.stop(); } catch (Exception ignored) {}
                rec.release();
                double rms = frames > 0 ? Math.sqrt((double) sum / frames) : 0;
                sb.append("frames=").append(frames).append(" rms=").append((long) rms).append(" peak=").append(peak).append("\n");
                sb.append(frames > 0 && peak > 0 ? "MIC OK\n" : "MIC SILENT\n");
            }
        } catch (Throwable t) {
            sb.append("MIC FAIL ").append(t.toString()).append("\n");
        }
        sb.append("--- CAMERA (camera0 JPEG) ---\n");
        HandlerThread ht = new HandlerThread("probe595");
        ht.start();
        android.os.Handler handler = new android.os.Handler(ht.getLooper());
        try {
            CameraManager cm = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
            String[] ids = cm.getCameraIdList();
            sb.append("ids=").append(Arrays.toString(ids)).append("\n");
            if (ids.length == 0) {
                sb.append("CAMERA FAIL: no ids\n");
            } else {
                String id = "0";
                boolean has0 = false;
                for (String c : ids) if ("0".equals(c)) has0 = true;
                if (!has0) id = ids[0];
                CameraCharacteristics ch = cm.getCameraCharacteristics(id);
                StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                Size[] sizes = map != null ? map.getOutputSizes(ImageFormat.JPEG) : null;
                if (sizes == null || sizes.length == 0) {
                    sb.append("CAMERA FAIL: no JPEG sizes for camera ").append(id).append("\n");
                } else {
                    Size size = sizes[0];
                    for (Size s : sizes) {
                        if (s.getWidth() <= 4000 && s.getHeight() <= 3000
                                && s.getWidth() * s.getHeight() > size.getWidth() * size.getHeight()) size = s;
                    }
                    final ImageReader reader = ImageReader.newInstance(size.getWidth(), size.getHeight(), ImageFormat.JPEG, 2);
                    final CountDownLatch acquired = new CountDownLatch(1);
                    final CountDownLatch opened = new CountDownLatch(1);
                    final String[] result = new String[1];
                    reader.setOnImageAvailableListener(r -> {
                        try (Image img = r.acquireNextImage()) {
                            java.nio.ByteBuffer b = img.getPlanes()[0].getBuffer();
                            byte[] data = new byte[b.remaining()];
                            b.get(data);
                            // 5.9.6 FIX (on-device 5.9.5 bug): the probe saved
                            // into external app storage, which failed with
                            // EACCES on the S26 FE even though the camera
                            // itself worked. Internal app storage is always
                            // writable, and the test photo never needs to
                            // leave the app. Failures now also report a
                            // plain reason instead of a raw exception.
                            File dir = new File(getFilesDir(), "probe");
                            if (!dir.exists()) dir.mkdirs();
                            if (!dir.exists()) {
                                result[0] = "CAMERA CAPTURE FAIL: could not create the save folder in internal storage (the camera itself may still work)";
                            } else {
                                File f = new File(dir, "capture.jpg");
                                try (OutputStream out = new FileOutputStream(f)) { out.write(data); }
                                result[0] = "CAMERA OK bytes=" + data.length + " " + img.getWidth() + "x" + img.getHeight() + " file=" + f.getAbsolutePath();
                            }
                        } catch (Throwable t) {
                            result[0] = "CAMERA CAPTURE FAIL: could not save the test photo: " + t.getMessage() + " (the camera itself may still work)";
                        }
                        acquired.countDown();
                    }, handler);
                    CameraDevice.StateCallback cb = new CameraDevice.StateCallback() {
                        @Override public void onOpened(CameraDevice d) {
                            opened.countDown();
                            try {
                                d.createCaptureSession(Arrays.asList(reader.getSurface()), new CameraCaptureSession.StateCallback() {
                                    @Override public void onConfigured(CameraCaptureSession session) {
                                        try {
                                            CaptureRequest.Builder b = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE);
                                            b.addTarget(reader.getSurface());
                                            session.capture(b.build(), new CameraCaptureSession.CaptureCallback() { }, handler);
                                        } catch (Throwable t) {
                                            result[0] = "CAMERA CAPTURE FAIL " + t;
                                            acquired.countDown();
                                        }
                                    }
                                    @Override public void onConfigureFailed(CameraCaptureSession session) {
                                        result[0] = "CAMERA CONFIGURE FAIL";
                                        acquired.countDown();
                                    }
                                }, handler);
                            } catch (Throwable t) {
                                result[0] = "CAMERA SESSION FAIL " + t;
                                acquired.countDown();
                            }
                        }
                        @Override public void onDisconnected(CameraDevice d) {
                            result[0] = "CAMERA DISCONNECTED";
                            opened.countDown(); acquired.countDown();
                        }
                        @Override public void onError(CameraDevice d, int code) {
                            result[0] = "CAMERA ERROR " + code;
                            opened.countDown(); acquired.countDown();
                        }
                    };
                    try {
                        cm.openCamera(id, cb, handler);
                    } catch (SecurityException se) {
                        sb.append("CAMERA SECURITY EXCEPTION ").append(se.toString()).append("\n");
                        reader.close();
                        return sb.toString();
                    }
                    if (!opened.await(10, TimeUnit.SECONDS)) {
                        sb.append("CAMERA open timeout\n");
                        reader.close();
                        return sb.toString();
                    }
                    acquired.await(10, TimeUnit.SECONDS);
                    sb.append(result[0] != null ? result[0] : "CAMERA no image").append("\n");
                    reader.close();
                }
            }
        } catch (CameraAccessException e) {
            sb.append("CAMERA ACCESS FAIL ").append(e.toString()).append("\n");
        } catch (Throwable t) {
            sb.append("CAMERA FAIL ").append(t.toString()).append("\n");
        } finally {
            try { ht.quitSafely(); } catch (Exception ignored) {}
        }
        return sb.toString();
    }

    private void saveLogcatAndShow() {
        // 5.9.11: own colorful bar.
        runBarTask(pbLog, tvLogProgress, "Saving logs…", () -> {
            File logDir = new File(getExternalFilesDir(null), "logs");
            if (!logDir.exists()) logDir.mkdirs();
            int logcatLines = 0;
            File logcatFile = new File(logDir, "logcat.txt");
            try {
                Process p = Runtime.getRuntime().exec(new String[]{"logcat", "-d"});
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                try (OutputStream out = new FileOutputStream(logcatFile)) {
                    String line;
                    while ((line = r.readLine()) != null) {
                        out.write((line + "\n").getBytes("UTF-8"));
                        logcatLines++;
                    }
                }
                p.waitFor();
            } catch (Exception e) {
                appendLog("Logcat capture failed: " + e.getMessage());
            }
            File opLog = new File(getFilesDir(), "operation_log.txt");
            File opCopy = new File(logDir, "operation_log.txt");
            try {
                if (opLog.exists()) {
                    try (java.io.FileInputStream in = new java.io.FileInputStream(opLog);
                         OutputStream out = new FileOutputStream(opCopy)) {
                        byte[] buf = new byte[32768];
                        int n;
                        while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
                    }
                }
            } catch (Exception ignored) {}
            StringBuilder guest = new StringBuilder();
            if (isRootGranted) {
                try {
                    Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c",
                        "for f in " + STAGE_DIR + "/takeover_app.log " + STAGE_DIR + "/restore_app.log " + currentSlotDir() + "/takeover_app.log; do [ -f \"$f\" ] && echo \"GUESTLOG:$f\"; done"});
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line;
                    while ((line = r.readLine()) != null) guest.append(line).append("\n");
                    p.waitFor();
                } catch (Exception ignored) {}
            }
            final String summary = "Logs saved to " + logDir.getAbsolutePath() + ":\n"
                    + "- operation_log.txt (this app's operation log, " + (opCopy.exists() ? opCopy.length() + " bytes" : "not written yet") + ")\n"
                    + "- logcat.txt (host logcat -d, " + logcatLines + " lines)\n"
                    + "- Guest log files present on disk:\n" + (guest.length() > 0 ? guest.toString() : "(none found — guest logs are the scripts' takeover/restore logs, only present after a boot/return run)\n")
                    + "NOTE: this viewer shows the HOST logcat and the app's own log. It does NOT show a guest-internal logcat (the guest userspace has no logcat capture wired here).";
            appendLog(summary);
            mainHandler.post(() -> new AlertDialog.Builder(MainActivity.this)
                .setTitle("Logs saved")
                .setMessage(summary)
                .setPositiveButton("OK", null)
                .show());
        });
    }
    // 5.9.5-APP-END

}
