#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <gdk/gdk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "mpv/mpv_plugin.h"

// Clears to transparent before Flutter draws each frame. Flutter's GTK
// compositor blends its frame over what is already in the buffer
// (gdk_cairo_draw_from_gl), and nothing clears a transparent window's buffer,
// so where a frame turns transparent (a hidden overlay over the video) the old
// pixels would stay on screen. Connected to Flutter's renderer widget (a
// GtkDrawingArea with its own GdkWindow) so it runs right before its draw.
static gboolean clear_window_cb(GtkWidget* widget, cairo_t* cr, gpointer user_data) {
  (void)widget;
  (void)user_data;
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
  cairo_paint(cr);
  cairo_restore(cr);
  return FALSE;
}

// Connects clear_window_cb to Flutter's renderer: the GtkDrawingArea inside
// the FlView.
static void connect_clear_to_renderer(GtkWidget* widget, gpointer user_data) {
  if (GTK_IS_DRAWING_AREA(widget)) {
    g_signal_connect(widget, "draw", G_CALLBACK(clear_window_cb), nullptr);
  } else if (GTK_IS_CONTAINER(widget)) {
    gtk_container_forall(GTK_CONTAINER(widget), connect_clear_to_renderer, user_data);
  }
}

// The native mpv video plane is a wl_subsurface stacked below this window's
// surface, so the window needs an alpha channel and a transparent Flutter
// background for the video to show through (from Plezy's runner).
static void enable_video_plane_transparency(GtkWindow* window, FlView* view) {
#ifdef GDK_WINDOWING_WAYLAND
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  if (!GDK_IS_WAYLAND_DISPLAY(display)) return;

  GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(window));
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (visual == nullptr) {
    g_warning("MPV video plane: no RGBA visual; the video plane would be hidden behind an opaque window");
    return;
  }

  gtk_widget_set_visual(GTK_WIDGET(window), visual);
  gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  connect_clear_to_renderer(GTK_WIDGET(view), nullptr);

  GdkRGBA transparent = {0.0, 0.0, 0.0, 0.0};
  fl_view_set_background_color(view, &transparent);
#else
  (void)window;
  (void)view;
#endif
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window = GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // A TV app: no title bar, full screen from the start.
  gtk_window_set_title(window, "IPTV");
  gtk_window_set_default_size(window, 1920, 1080);
  if (g_getenv("COUCHBOX_IPTV_WINDOWED") == nullptr) gtk_window_fullscreen(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  enable_video_plane_transparency(window, view);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // The native mpv video plane (vendored from Plezy, see runner/mpv/README.md).
  FlPluginRegistrar* registrar = fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view), "MpvPlugin");
  mpv_plugin_register_with_registrar(registrar);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
