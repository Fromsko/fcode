// ignore_for_file: invalid_use_of_protected_member
part of 'chat_page.dart';

extension _Upload on _ChatPageState {
  /// RPC 不取消也不重放；卡片身份与原绑定共同决定能否接收结果。
  Future<void> _pickFile() async {
    if (_uploading || _picking || _sending || !_online) return;
    final target = (
      widget.state,
      widget.desktopId,
      widget.sessionId,
      widget.projectId,
      widget.botId,
      _binding.generation,
      _editAnchor,
    );
    final ticket = Object();
    _fileSelection = ticket;
    bool current() =>
        mounted &&
        target ==
            (
              widget.state,
              widget.desktopId,
              widget.sessionId,
              widget.projectId,
              widget.botId,
              _binding.generation,
              _editAnchor,
            );
    DraftFile? selected;
    bool owns() =>
        current() &&
        selected != null &&
        _files.any((file) => file.token == selected!.token);
    final state = widget.state;
    setState(() => _error = null);
    _composerFocus.unfocus();
    try {
      final file = await pickUploadFile(state);
      if (!current() || _fileSelection != ticket || file == null) return;
      final card = DraftFile(name: file.name, size: file.bytes.length);
      selected = card;
      _files.add(card);
      _fileSelection = null;
      _draftChanged();
      if (_editIndex == null) _saveDraft(_composer.text);
      final path = await uploadFile(
        state,
        desktop: target.$2,
        project: target.$4,
        bot: target.$5,
        file: file,
      );
      if (!owns()) return;
      final index = _files.indexWhere((item) => item.token == card.token);
      _files[index] = card.resolved(path: path, status: DraftFileStatus.ready);
      _draftChanged();
      if (_editIndex == null) _saveDraft(_composer.text);
    } catch (error) {
      if (!current()) return;
      final message = userMessage(state, error);
      final status = error is UploadUnconfirmed
          ? DraftFileStatus.unconfirmed
          : DraftFileStatus.failed;
      if (selected == null && _fileSelection == ticket) {
        _files.add(
          DraftFile(
            name: error is UploadSelectionFailure ? error.name : '',
            size: error is UploadSelectionFailure ? error.size : null,
            status: status,
            error: message,
          ),
        );
      } else if (owns()) {
        final index = _files.indexWhere(
          (item) => item.token == selected!.token,
        );
        _files[index] = selected!.resolved(status: status, error: message);
      } else {
        return;
      }
      _draftChanged();
      if (_editIndex == null) _saveDraft(_composer.text);
    } finally {
      if (mounted && _fileSelection == ticket) {
        setState(() => _fileSelection = null);
      }
    }
  }

  /// 项目文件选择仍是普通 @ 提及，不转为上传附件。
  void _insertFileMention(String path) {
    _mentions.add(path);
    final value = _composer.value;
    final at = value.selection.isValid
        ? value.selection.end
        : value.text.length;
    final separator = at > 0 && !RegExp(r'\s').hasMatch(value.text[at - 1])
        ? ' '
        : '';
    final insert = '$separator${fileMentionText(path)} ';
    _composer.value = TextEditingValue(
      text: value.text.replaceRange(at, at, insert),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
    _draftChanged();
  }

  void _removeFile(DraftFile file) {
    if (_sending) return;
    _files.removeWhere((item) => item.token == file.token);
    _draftChanged();
    if (_editIndex == null) _saveDraft(_composer.text);
  }

  /// 断线、换会话或离开页面后，未完成的上传只能显示未确认，不能恢复为成功。
  void _invalidateFileUploads() {
    _fileSelection = null;
    for (var i = 0; i < _files.length; i++) {
      final file = _files[i];
      if (file.status == DraftFileStatus.uploading) {
        // 新身份使原 RPC 即使之后返回也无法匹配。
        _files[i] = DraftFile(
          name: file.name,
          size: file.size,
          status: DraftFileStatus.unconfirmed,
          error: tr(
            '上传未确认，请移除后重新选择；不会自动重试。',
            'Upload unconfirmed. Remove and select again; no automatic retry.',
          ),
        );
      }
    }
  }
}
