use crate::i18n::tr;
use crate::traymenu;
use tauri::menu::{Menu, MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Wry};

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_menu(app)?;
    let mut builder = TrayIconBuilder::with_id("main");
    // Windows does not tint tray icons and the monochrome outline vanishes on a dark taskbar, so
    // the app's own mark is the icon. trayicon::app_mark explains why at length.
    if let Some(icon) = crate::trayicon::app_mark() {
        builder = builder.icon(icon);
    }
    builder
        .tooltip(concat!("Codenotch v", env!("CARGO_PKG_VERSION")))
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, ev| handle(app, ev.id().as_ref()))
        .build(app)?;
    Ok(())
}

/// The readings themselves, as the Mac's menu bar shows them: a line per provider with its headline
/// figure, and under it one greyed line per limit window. The macOS menu is rebuilt as it opens;
/// Tauri has no such hook, so `refresh_menu` is called whenever a reading changes and once a minute
/// besides, which keeps "Resets in 12 min" honest.
pub fn build_menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let lang = language(app);
    let now = crate::now_ms();
    let mut items: Vec<tauri::menu::MenuItem<Wry>> = Vec::new();
    for id in crate::TRAY_PROVIDER_IDS {
        let snap = crate::snapshot_of(app, id);
        if snap.status == "absent" {
            continue;
        }
        let head = traymenu::header(
            crate::provider_label(id),
            crate::ring_fraction(app, id),
            traymenu::stale_since(&snap, now),
            now,
            &lang,
        );
        // Clicking a provider re-reads that one, as on the Mac.
        items.push(MenuItemBuilder::with_id(format!("refresh:{id}"), head).build(app)?);
        for (n, line) in traymenu::provider_lines(&snap, now, &lang).iter().enumerate() {
            // Windows does not indent submenu-less items, so the indent is in the text.
            items.push(
                MenuItemBuilder::with_id(format!("line:{id}:{n}"), format!("    {line}"))
                    .enabled(false)
                    .build(app)?,
            );
        }
    }
    if items.is_empty() {
        items.push(
            MenuItemBuilder::with_id("waiting", tr(&lang, "waiting"))
                .enabled(false)
                .build(app)?,
        );
    }
    let refresh = MenuItemBuilder::with_id("refresh", tr(&lang, "refresh_all")).build(app)?;
    let settings = MenuItemBuilder::with_id("settings", tr(&lang, "settings")).build(app)?;
    let quit = MenuItemBuilder::with_id("quit", tr(&lang, "quit_app")).build(app)?;
    let mut menu = MenuBuilder::new(app);
    for item in &items {
        menu = menu.item(item);
    }
    menu.separator()
        .item(&refresh)
        .item(&settings)
        .separator()
        .item(&quit)
        .build()
}

/// The language the menu speaks, already resolved: `traymenu` picks its wording by code and has no
/// "auto" of its own.
fn language(app: &AppHandle) -> String {
    let st = app.state::<crate::AppState>();
    let raw = st.cfg.lock().unwrap().lang.clone();
    if raw == "auto" {
        crate::i18n::resolve_auto().to_string()
    } else {
        raw
    }
}

/// The hover text: the same figures the menu opens with, for when the menu is not open.
fn tooltip(app: &AppHandle) -> String {
    let mut parts: Vec<String> = Vec::new();
    for id in crate::TRAY_PROVIDER_IDS {
        if crate::snapshot_of(app, id).status == "absent" {
            continue;
        }
        let value = crate::ring_fraction(app, id)
            .map(|f| format!("{}%", traymenu::pct(f)))
            .unwrap_or_else(|| "—".into());
        parts.push(format!("{} {value}", crate::provider_label(id)));
    }
    if parts.is_empty() {
        concat!("Codenotch v", env!("CARGO_PKG_VERSION")).to_string()
    } else {
        format!("Codenotch — {}", parts.join(" · "))
    }
}

/// Rebuilds the tray menu, ALWAYS on the main thread.
///
/// A menu is a Windows UI object. Building one or swapping it in from another thread leaves the
/// tray holding a menu that never opens again — and since changing the language is what triggers a
/// rebuild, the user is then locked out of the only place they could change it back. The tray's own
/// click handlers already run on the main thread, but the readings poller and the settings window
/// do not, so the hop is done here once rather than being remembered at every call site.
pub fn refresh_menu(app: &AppHandle) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(tray) = handle.tray_by_id("main") {
            match build_menu(&handle) {
                Ok(menu) => {
                    let _ = tray.set_menu(Some(menu));
                    let _ = tray.set_tooltip(Some(&tooltip(&handle)));
                }
                Err(e) => crate::applog(&format!("tray menu: {e}")),
            }
        }
    });
}

/// Provider rows carry `refresh:<id>`; everything else the menu offers is one of the four fixed
/// items. Settings, language, hooks and the rest arrive as commands from the settings window.
fn handle(app: &AppHandle, id: &str) {
    if let Some(provider) = id.strip_prefix("refresh:") {
        refresh_provider(app, provider);
        return;
    }
    match id {
        "refresh" => {
            for provider in crate::TRAY_PROVIDER_IDS {
                refresh_provider(app, provider);
            }
            let a = app.clone();
            std::thread::spawn(move || crate::reload_glyphs(&a));
        }
        "settings" => crate::settings_window::open(app),
        "quit" => app.exit(0),
        _ => {}
    }
}

/// Asks one provider to read again. Claude's backoff is cleared first: asking for a reading is the
/// user saying they want it now, not in fifteen minutes.
fn refresh_provider(app: &AppHandle, provider: &str) {
    match provider {
        "codex" => crate::codex::request_refresh(),
        "cursor" => crate::cursor::request_refresh(),
        "gemini" => crate::antigravity::request_refresh(),
        _ => {
            {
                let st = app.state::<crate::AppState>();
                let mut u = st.usage.lock().unwrap();
                u.backoff_until = 0;
            }
            crate::usage::request_refresh();
        }
    }
}
