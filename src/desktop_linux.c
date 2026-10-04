#include <gtk/gtk.h>
#include <gio/gio.h>
#include <string.h>

extern void ghostfile_theme_changed(int dark);
extern void ghostfile_review_transfer(const char *id);
extern void ghostfile_quit_requested(void);
static GtkApplication *application;
static GtkWindow *parent;
static GSettings *appearance;
static GDBusConnection *bus;
static guint portal_subscription;
static int portal_scheme = -1;

int ghostfile_desktop_dark(void) {
    const char *override = g_getenv("ORIEL_COLOR_SCHEME");
    if (override) return strcmp(override, "dark") == 0;
    if (portal_scheme == 1 || portal_scheme == 2) return portal_scheme == 1;
    if (appearance) {
        char *scheme = g_settings_get_string(appearance, "color-scheme");
        int result = strcmp(scheme, "prefer-dark") == 0;
        int explicit_light = strcmp(scheme, "prefer-light") == 0;
        g_free(scheme);
        if (result || explicit_light) return result;
    }
    gboolean dark = FALSE;
    char *theme = NULL;
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, "gtk-theme-name", &theme, NULL);
    if (theme && (g_strrstr(theme, "dark") || g_strrstr(theme, "Dark"))) dark = TRUE;
    g_free(theme);
    return dark;
}
static void theme_changed(void) { ghostfile_theme_changed(ghostfile_desktop_dark()); }
static void settings_changed(GSettings *settings, gchar *key, gpointer data) {
    (void)settings; (void)key; (void)data; theme_changed();
}
static void gtk_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data; theme_changed();
}
static void portal_changed(GDBusConnection *connection, const gchar *sender, const gchar *path,
                           const gchar *interface, const gchar *signal, GVariant *parameters, gpointer data) {
    (void)connection; (void)sender; (void)path; (void)interface; (void)signal; (void)data;
    const char *ns, *key;
    GVariant *value;
    g_variant_get(parameters, "(&s&sv)", &ns, &key, &value);
    if (!strcmp(ns, "org.freedesktop.appearance") && !strcmp(key, "color-scheme") && g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) {
        portal_scheme = (int)g_variant_get_uint32(value);
        theme_changed();
    }
    g_variant_unref(value);
}
static void review(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)data;
    if (parameter) ghostfile_review_transfer(g_variant_get_string(parameter, NULL));
}
void ghostfile_desktop_init(void *app, void *window) {
    application = g_object_ref(app); parent = window;
    GSettingsSchemaSource *source = g_settings_schema_source_get_default();
    GSettingsSchema *schema = source ? g_settings_schema_source_lookup(source, "org.gnome.desktop.interface", TRUE) : NULL;
    if (schema) {
        if (g_settings_schema_has_key(schema, "color-scheme")) {
            appearance = g_settings_new_full(schema, NULL, NULL);
            g_signal_connect(appearance, "changed::color-scheme", G_CALLBACK(settings_changed), NULL);
        }
        g_settings_schema_unref(schema);
    }
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) {
        g_signal_connect(settings, "notify::gtk-application-prefer-dark-theme", G_CALLBACK(gtk_changed), NULL);
        g_signal_connect(settings, "notify::gtk-theme-name", G_CALLBACK(gtk_changed), NULL);
    }
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (bus) {
        portal_subscription = g_dbus_connection_signal_subscribe(bus, "org.freedesktop.portal.Desktop",
            "org.freedesktop.portal.Settings", "SettingChanged", "/org/freedesktop/portal/desktop", NULL,
            G_DBUS_SIGNAL_FLAGS_NONE, portal_changed, NULL, NULL);
        GVariant *reply = g_dbus_connection_call_sync(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Settings", "ReadOne", g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"),
            G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 1000, NULL, NULL);
        if (reply) {
            GVariant *value; g_variant_get(reply, "(v)", &value);
            if (g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) portal_scheme = (int)g_variant_get_uint32(value);
            g_variant_unref(value); g_variant_unref(reply);
        }
    }
    GSimpleAction *action = g_simple_action_new("review-transfer", G_VARIANT_TYPE_STRING);
    g_signal_connect(action, "activate", G_CALLBACK(review), NULL);
    g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(action));
    g_object_unref(action);
    theme_changed();
}
void ghostfile_desktop_cleanup(void) {
    if (bus && portal_subscription) g_dbus_connection_signal_unsubscribe(bus, portal_subscription);
    g_clear_object(&bus); g_clear_object(&appearance);
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) g_signal_handlers_disconnect_by_func(settings, G_CALLBACK(gtk_changed), NULL);
    if (application) g_action_map_remove_action(G_ACTION_MAP(application), "review-transfer");
    g_clear_object(&application); parent = NULL;
}
void ghostfile_desktop_notify(const char *id, const char *kind, const char *name) {
    if (!application) return;
    if (!strcmp(kind, "dismiss")) { g_application_withdraw_notification(G_APPLICATION(application), id); return; }
    int incoming = !strcmp(kind, "request");
    GNotification *notification = g_notification_new(incoming ? "Incoming files" : "Files received");
    char *body = g_strdup_printf(incoming ? "%s wants to share files. Review the code and choose where to save." : "Files from %s are ready. Open GhostFile to view them.", name);
    g_notification_set_body(notification, body); g_free(body);
    g_notification_set_priority(notification, incoming ? G_NOTIFICATION_PRIORITY_HIGH : G_NOTIFICATION_PRIORITY_NORMAL);
    GIcon *icon = g_themed_icon_new("dev.ghostfile.App");
    g_notification_set_icon(notification, icon); g_object_unref(icon);
    g_notification_set_default_action_and_target(notification, "app.review-transfer", "s", id);
    g_notification_add_button_with_target(notification, incoming ? "Review" : "Open GhostFile", "app.review-transfer", "s", id);
    g_application_send_notification(G_APPLICATION(application), id, notification);
    g_object_unref(notification);
}
int ghostfile_open_path(const char *path) {
    gchar *uri = g_filename_to_uri(path, NULL, NULL);
    if (!uri) return 0;
    gboolean result = g_app_info_launch_default_for_uri(uri, NULL, NULL);
    g_free(uri); return result;
}
typedef struct { GMutex mutex; GCond condition; gboolean done; gchar *path; } FolderCall;
static void folder_finished(GObject *source, GAsyncResult *result, gpointer data) {
    FolderCall *call = data;
    GFile *file = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(source), result, NULL);
    g_mutex_lock(&call->mutex);
    if (file) { call->path = g_file_get_path(file); g_object_unref(file); }
    call->done = TRUE; g_cond_signal(&call->condition); g_mutex_unlock(&call->mutex);
}
static gboolean folder_start(gpointer data) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Save incoming files in…");
    gtk_file_dialog_select_folder(dialog, parent, NULL, folder_finished, data);
    g_object_unref(dialog); return G_SOURCE_REMOVE;
}
char *ghostfile_select_folder(void) {
    FolderCall call = {0};
    g_mutex_init(&call.mutex); g_cond_init(&call.condition);
    g_mutex_lock(&call.mutex);
    g_idle_add_full(G_PRIORITY_DEFAULT, folder_start, &call, NULL);
    while (!call.done) g_cond_wait(&call.condition, &call.mutex);
    g_mutex_unlock(&call.mutex);
    g_mutex_clear(&call.mutex); g_cond_clear(&call.condition);
    return call.path;
}
void ghostfile_desktop_free(void *pointer) { g_free(pointer); }
static gboolean quit_idle(gpointer data) {
    (void)data;
    ghostfile_quit_requested();
    return G_SOURCE_REMOVE;
}
void ghostfile_desktop_quit(void) {
    GListModel *windows = gtk_window_get_toplevels();
    guint count = g_list_model_get_n_items(windows);
    for (guint index = 0; index < count; index++) {
        GtkWindow *window = g_list_model_get_item(windows, index);
        if (window != parent) gtk_window_close(window);
        g_object_unref(window);
    }
    /* Let dialog completions wake IPC workers before stopping the event loop. */
    g_idle_add_full(G_PRIORITY_LOW, quit_idle, NULL, NULL);
}
