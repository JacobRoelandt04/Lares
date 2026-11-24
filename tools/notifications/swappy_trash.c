/* swappy_trash.c -- make swappy's "delete" button delete the SCREENSHOT it was opened on.
 *
 * swappy 1.8's trash-can button is "Clear Paints" (icon edit-delete-symbolic, handler clear_clicked_handler):
 * it wipes the drawing, never the file. swappy has no option, hook or D-Bus action for deleting the file, and
 * the window must stay open so that Save writes the shot back, so this is a LD_PRELOAD shim, loaded by tools/notifications/shot_edit.sh for swappy alone.
 *
 * swappy wires its handlers with gtk_builder_connect_signals(), which finds them by name in the executable (it is
 * linked -rdynamic). The shim wraps that one call: first it registers its own function under the name
 * "clear_clicked_handler" (an explicitly added callback symbol wins over the module lookup), and sets the button's
 * tooltip; then it calls the real function. Our handler runs $LARES_SHOT_TRASH <$LARES_SHOT_FILE> detached: the helper
 * moves the file to the Trash and tells the shell. The drawing is NOT cleared and the window stays: Save writes the
 * picture (with its paints) to the same path again, which is the recovery. Without LARES_SHOT_FILE nothing is changed.
 * The keys x / k keep swappy's own "clear paints".
 *
 * Build: cc -shared -fPIC -o swappy_trash.so swappy_trash.c $(pkg-config --cflags gtk+-3.0) -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <gtk/gtk.h>
#include <stdlib.h>

static void lares_delete_shot(GtkWidget *button, gpointer data)
{
    const char *helper = getenv("LARES_SHOT_TRASH");
    const char *file = getenv("LARES_SHOT_FILE");
    (void)button;
    (void)data;
    if (!helper || !*helper || !file || !*file)
        return;
    char *argv[] = { (char *)helper, (char *)file, NULL };
    GError *err = NULL;
    if (!g_spawn_async(NULL, argv, NULL,
                       G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL | G_SPAWN_SEARCH_PATH,
                       NULL, NULL, NULL, &err)) {
        g_printerr("swappy_trash: cannot run %s: %s\n", helper, err ? err->message : "?");
        g_clear_error(&err);
    }
}

void gtk_builder_connect_signals(GtkBuilder *builder, gpointer user_data)
{
    static void (*real)(GtkBuilder *, gpointer);
    if (!real)
        real = (void (*)(GtkBuilder *, gpointer))dlsym(RTLD_NEXT, "gtk_builder_connect_signals");
    const char *file = getenv("LARES_SHOT_FILE");
    if (file && *file) {
        gtk_builder_add_callback_symbol(builder, "clear_clicked_handler", G_CALLBACK(lares_delete_shot));
        GObject *clear = gtk_builder_get_object(builder, "clear");
        if (clear && GTK_IS_WIDGET(clear))
            gtk_widget_set_tooltip_text(GTK_WIDGET(clear), "Delete the screenshot (Save brings it back)");
    }
    real(builder, user_data);
}
