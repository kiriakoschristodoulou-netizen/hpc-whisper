package android.view.inputmethod;
public interface InputConnection {
 boolean beginBatchEdit(); boolean endBatchEdit(); boolean commitText(CharSequence t,int p); boolean setComposingText(CharSequence t,int p);
 boolean finishComposingText(); boolean deleteSurroundingText(int a,int b); boolean performContextMenuAction(int id); boolean performEditorAction(int a);
 boolean sendKeyEvent(android.view.KeyEvent e);
}
