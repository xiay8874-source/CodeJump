package com.xiay8874.codejump;
import com.intellij.openapi.actionSystem.*;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.project.DumbAware;
import org.jetbrains.annotations.NotNull;
public final class StartBridgeAction extends AnAction implements DumbAware {
  @Override public void actionPerformed(@NotNull AnActionEvent event) {
    ApplicationManager.getApplication().getService(BridgeService.class).start();
  }
}
