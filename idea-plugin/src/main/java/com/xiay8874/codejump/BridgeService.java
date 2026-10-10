package com.xiay8874.codejump;

import com.google.gson.*;
import com.intellij.openapi.Disposable;
import com.intellij.openapi.application.*;
import com.intellij.openapi.diagnostic.Logger;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.fileEditor.*;
import com.intellij.openapi.project.*;
import com.intellij.openapi.vfs.*;
import com.intellij.psi.*;
import com.intellij.psi.search.*;
import com.intellij.util.concurrency.AppExecutorUtil;
import com.sun.net.httpserver.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;

/** Only loopback + a per-process bearer may access the bridge. No shell execution or arbitrary file open. */
public final class BridgeService implements Disposable {
  private static final Logger LOG = Logger.getInstance(BridgeService.class);
  private static final Gson JSON = new Gson();
  private HttpServer server;
  private Path discovery;
  private String token;
  private ExecutorService executor;
  private final Map<String, Target> targets = new LinkedHashMap<>();
  private record Target(Project project, SmartPsiElementPointer<PsiElement> pointer, long created) {}

  public synchronized void start() {
    if (server != null) return;
    try {
      token = UUID.randomUUID().toString() + UUID.randomUUID();
      server = HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 4);
      executor = new ThreadPoolExecutor(2, 2, 0, TimeUnit.SECONDS, new ArrayBlockingQueue<>(16), r -> {
        Thread thread = new Thread(r, "CodeJump bridge"); thread.setDaemon(true); return thread;
      }, new ThreadPoolExecutor.AbortPolicy());
      server.setExecutor(executor);
      server.createContext("/", this::handle);
      Path directory = Path.of(System.getProperty("user.home"), "Library", "Application Support", "CodeJump", "idea");
      Files.createDirectories(directory);
      Files.setPosixFilePermissions(directory, PosixFilePermissions.fromString("rwx------"));
      discovery = directory.resolve(ProcessHandle.current().pid() + ".json");
      JsonObject record = new JsonObject();
      record.addProperty("port", server.getAddress().getPort()); record.addProperty("token", token);
      record.addProperty("pid", ProcessHandle.current().pid()); record.addProperty("home", PathManager.getHomePath());
      Path temporary = Files.createTempFile(directory, "endpoint", ".tmp", PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
      Files.writeString(temporary, JSON.toJson(record));
      Files.move(temporary, discovery, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
      server.start();
    } catch (Exception error) { LOG.warn("CodeJump bridge could not start", error); dispose(); }
  }

  private void handle(HttpExchange exchange) {
    try (exchange) {
      if (!exchange.getRemoteAddress().getAddress().isLoopbackAddress()
          || exchange.getRequestHeaders().containsKey("Origin")
          || !MessageDigest.isEqual(("Bearer " + token).getBytes(StandardCharsets.UTF_8),
               Optional.ofNullable(exchange.getRequestHeaders().getFirst("Authorization")).orElse("").getBytes(StandardCharsets.UTF_8))) {
        reply(exchange, 401, Map.of("error", "unauthorized")); return;
      }
      if (!exchange.getRequestMethod().equals("POST")) { reply(exchange, 405, Map.of("error", "post_required")); return; }
      byte[] data = exchange.getRequestBody().readNBytes(16385);
      if (data.length > 16384) { reply(exchange, 413, Map.of("error", "too_large")); return; }
      JsonObject input = JsonParser.parseString(new String(data, StandardCharsets.UTF_8)).getAsJsonObject();
      String path = exchange.getRequestURI().getPath();
      if (path.equals("/projects")) {
        Object result = ReadAction.compute(() -> Arrays.stream(ProjectManager.getInstance().getOpenProjects())
          .filter(p -> !p.isDisposed() && p.getBasePath() != null)
          .map(p -> Map.of("name", p.getName(), "path", canonical(p.getBasePath()))).toList());
        reply(exchange, 200, result);
      } else if (path.equals("/resolve")) {
        Future<Object> task = AppExecutorUtil.getAppExecutorService().submit(() -> ReadAction.compute(() -> resolveBatch(input)));
        try { reply(exchange, 200, task.get(1500, TimeUnit.MILLISECONDS)); }
        catch (TimeoutException error) { task.cancel(true); reply(exchange, 503, Map.of("error", "index_busy")); }
      } else if (path.equals("/navigate")) {
        Target target;
        synchronized (targets) { target = targets.get(string(input, "target")); }
        if (target == null || target.project.isDisposed() || System.currentTimeMillis() - target.created > 300_000) {
          reply(exchange, 409, Map.of("error", "target_expired")); return;
        }
        // Resolve the smart pointer again on EDT; offsets never come from the caller.
        FutureTask<Boolean> navigation = new FutureTask<>(() -> {
          if (target.project.isDisposed()) return false;
          PsiElement element = target.pointer.getElement();
          if (element == null || !element.isValid()) return false;
          PsiElement location = element.getNavigationElement();
          if (location instanceof com.intellij.pom.Navigatable navigatable && navigatable.canNavigate()) {
            navigatable.navigate(true); return true;
          }
          return false;
        });
        ApplicationManager.getApplication().invokeLater(navigation, ModalityState.nonModal());
        try {
          boolean opened = navigation.get(1500, TimeUnit.MILLISECONDS);
          reply(exchange, opened ? 200 : 409, Map.of("accepted", opened));
        } catch (TimeoutException error) {
          navigation.cancel(false); reply(exchange, 503, Map.of("error", "editor_busy"));
        }
      } else if (path.equals("/selection")) {
        FutureTask<Object> selection = new FutureTask<>(() -> {
          List<Map<String, Object>> selected = new ArrayList<>();
          for (Project project : ProjectManager.getInstance().getOpenProjects()) {
            if (project.isDisposed()) continue;
            var editor = FileEditorManager.getInstance(project).getSelectedTextEditor();
            if (editor == null) continue;
            var file = FileDocumentManager.getInstance().getFile(editor.getDocument());
            if (file != null) selected.add(Map.of("project", canonical(project.getBasePath()), "path", file.getUrl(),
                "line", editor.getCaretModel().getLogicalPosition().line + 1));
          }
          return selected;
        });
        ApplicationManager.getApplication().invokeLater(selection, ModalityState.nonModal());
        try { reply(exchange, 200, selection.get(1500, TimeUnit.MILLISECONDS)); }
        catch (TimeoutException error) { selection.cancel(false); reply(exchange, 503, Map.of("error", "editor_busy")); }
      } else { reply(exchange, 404, Map.of("error", "not_found")); }
    } catch (Exception error) { LOG.debug("CodeJump request failed", error); }
  }

  private Object resolveBatch(JsonObject input) {
    if (!input.has("requests")) return resolve(input);
    List<Object> results = new ArrayList<>();
    JsonArray requests = input.getAsJsonArray("requests");
    if (requests.size() > 64) return results;
    for (JsonElement request : requests) {
      if (Thread.currentThread().isInterrupted() || results.size() >= 128) break;
      results.addAll((List<?>) resolve(request.getAsJsonObject()));
    }
    return results;
  }

  private Object resolve(JsonObject input) {
    String root = string(input, "project");
    Project project = Arrays.stream(ProjectManager.getInstance().getOpenProjects())
      .filter(p -> !p.isDisposed() && p.getBasePath() != null && canonical(p.getBasePath()).equals(root)).findFirst().orElse(null);
    if (project == null || DumbService.isDumb(project)) return List.of();
    String symbol = string(input, "symbol").replace('$', '.');
    String filePath = string(input, "path");
    String signature = string(input, "signature");
    if (symbol.length() > 512 || filePath.length() > 4096) return List.of();
    int separator = Math.max(symbol.lastIndexOf('#'), symbol.lastIndexOf('.'));
    String owner = separator < 0 ? symbol : symbol.substring(0, separator);
    String method = separator < 0 ? "" : symbol.substring(separator + 1);
    if (!method.isEmpty() && Character.isUpperCase(method.charAt(0)) && !symbol.contains("#")) { owner = symbol; method = ""; }
    List<PsiClass> classes = new ArrayList<>();
    GlobalSearchScope scope = GlobalSearchScope.allScope(project);
    if (!filePath.isEmpty()) {
      Path local = Path.of(filePath);
      if (!local.isAbsolute()) local = Path.of(root).resolve(local);
      String canonical = canonical(local.toString());
      if (canonical.isEmpty() || !Path.of(canonical).startsWith(Path.of(root))) return List.of();
      VirtualFile virtualFile = LocalFileSystem.getInstance().findFileByPath(canonical);
      PsiFile psi = virtualFile == null ? null : PsiManager.getInstance(project).findFile(virtualFile);
      if (psi instanceof PsiJavaFile javaFile) classes.addAll(Arrays.asList(javaFile.getClasses()));
      if (separator < 0 && !symbol.isEmpty() && Character.isLowerCase(symbol.charAt(0))) { method = symbol; owner = ""; }
    } else if (!owner.isEmpty()) {
      if (owner.contains(".")) classes.addAll(Arrays.asList(JavaPsiFacade.getInstance(project).findClasses(owner, scope)));
      else classes.addAll(Arrays.asList(PsiShortNamesCache.getInstance(project).getClassesByName(owner, scope)));
    }
    List<Map<String, Object>> results = new ArrayList<>();
    for (PsiClass type : classes) {
      if (Thread.currentThread().isInterrupted()) break;
      if (!owner.isEmpty() && !owner.equals(type.getName()) && !owner.equals(type.getQualifiedName())) continue;
      if (method.isEmpty()) addTarget(results, project, type, type.getQualifiedName(), "");
      else for (PsiMethod declaration : type.findMethodsByName(method, true)) {
        if (results.size() >= 64) break;
        PsiParameter[] parameters = declaration.getParameterList().getParameters();
        String readable = Arrays.stream(parameters).map(p -> p.getType().getPresentableText()).reduce((a,b) -> a + ", " + b).orElse("");
        String qualified = Arrays.stream(parameters).map(p -> p.getType().getCanonicalText()).reduce((a,b) -> a + ", " + b).orElse("");
        if (!signature.isEmpty() && !normalize(signature).equals(normalize(readable)) && !normalize(signature).equals(normalize(qualified))) continue;
        String declaring = declaration.getContainingClass() == null ? owner : declaration.getContainingClass().getQualifiedName();
        addTarget(results, project, declaration, declaring + "#" + method, method + "(" + readable + ")");
      }
      if (results.size() >= 64) break;
    }
    return results;
  }

  private void addTarget(List<Map<String, Object>> results, Project project, PsiElement original, String symbol, String signature) {
    PsiElement element = original.getNavigationElement();
    PsiFile file = element.getContainingFile();
    if (file == null || file.getVirtualFile() == null) return;
    VirtualFile virtual = file.getVirtualFile();
    Document document = PsiDocumentManager.getInstance(project).getDocument(file);
    int line = document == null ? 0 : document.getLineNumber(Math.min(element.getTextOffset(), document.getTextLength())) + 1;
    String id = UUID.randomUUID().toString();
    synchronized (targets) {
      targets.entrySet().removeIf(e -> System.currentTimeMillis() - e.getValue().created > 300_000);
      while (targets.size() >= 512) targets.remove(targets.keySet().iterator().next());
      targets.put(id, new Target(project, SmartPointerManager.getInstance(project).createSmartPsiElementPointer(original), System.currentTimeMillis()));
    }
    Map<String, Object> result = new LinkedHashMap<>();
    result.put("target", id); result.put("project", canonical(project.getBasePath()));
    result.put("path", virtual.getFileSystem().getProtocol().equals("file") ? virtual.getPath() : virtual.getUrl());
    result.put("line", line); result.put("symbol", symbol == null ? "" : symbol); result.put("signature", signature);
    List<Map<String, Object>> preview = new ArrayList<>();
    if (document != null && line > 0) for (int i = Math.max(0, line - 5); i < Math.min(document.getLineCount(), line + 4); i++) {
      int start = document.getLineStartOffset(i), end = Math.min(document.getLineEndOffset(i), start + 400);
      preview.add(Map.of("number", i + 1, "text", document.getImmutableCharSequence().subSequence(start, end).toString(), "highlighted", i + 1 == line));
    }
    result.put("preview", preview); results.add(result);
  }
  private static String normalize(String value) { return value.replaceAll("\\s+", ""); }
  private static String string(JsonObject input, String key) { return input.has(key) && !input.get(key).isJsonNull() ? input.get(key).getAsString() : ""; }
  private static String canonical(String value) { try { return Path.of(value).toRealPath().toString(); } catch (Exception ignored) { return ""; } }
  private static void reply(HttpExchange exchange, int status, Object value) throws java.io.IOException {
    byte[] data = JSON.toJson(value).getBytes(StandardCharsets.UTF_8);
    exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
    exchange.getResponseHeaders().set("Cache-Control", "no-store");
    exchange.sendResponseHeaders(status, data.length); exchange.getResponseBody().write(data);
  }
  @Override public synchronized void dispose() {
    if (server != null) server.stop(0); server = null;
    if (executor != null) executor.shutdownNow(); executor = null;
    if (discovery != null) try { Files.deleteIfExists(discovery); } catch (Exception ignored) {}
    synchronized (targets) { targets.clear(); }
  }
}
