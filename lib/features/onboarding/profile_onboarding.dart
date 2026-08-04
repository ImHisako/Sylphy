import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/profile/user_profile.dart';

typedef ProfilePhotoPicker = Future<Uint8List?> Function();

class ProfileOnboarding extends StatefulWidget {
  const ProfileOnboarding({
    super.key,
    required this.profileStore,
    required this.onCompleted,
    this.photoPicker,
  });

  final UserProfileStore profileStore;
  final ValueChanged<UserProfile> onCompleted;
  final ProfilePhotoPicker? photoPicker;

  @override
  State<ProfileOnboarding> createState() => _ProfileOnboardingState();
}

class _ProfileOnboardingState extends State<ProfileOnboarding> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  Uint8List? _photoBytes;
  bool _isSaving = false;
  String? _errorText;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final bytes = await (widget.photoPicker ?? _pickImageFile)();
      if (bytes == null || !mounted) {
        return;
      }
      if (bytes.length > maxProfilePhotoBytes) {
        setState(() => _errorText = 'La foto deve pesare meno di 5 MB.');
        return;
      }
      setState(() {
        _photoBytes = bytes;
        _errorText = null;
      });
    } on Exception {
      if (mounted) {
        setState(() => _errorText = 'Non è stato possibile leggere la foto.');
      }
    }
  }

  Future<void> _complete() async {
    if (!_formKey.currentState!.validate() || _isSaving) {
      return;
    }
    setState(() {
      _isSaving = true;
      _errorText = null;
    });
    try {
      final profile = await widget.profileStore.save(
        displayName: _nameController.text,
        photoBytes: _photoBytes,
      );
      if (mounted) {
        widget.onCompleted(profile);
      }
    } on Exception {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _errorText = 'Impossibile salvare il profilo sul dispositivo.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 42,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Crea il tuo profilo',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Scegli il nome che vedranno i tuoi contatti. Potrai aggiungere una foto, ma non è obbligatoria.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFAEB7C3), height: 1.45),
                    ),
                    const SizedBox(height: 28),
                    Center(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          CircleAvatar(
                            key: const ValueKey('onboarding-avatar'),
                            radius: 54,
                            backgroundColor: const Color(0xFF252C35),
                            backgroundImage: _photoBytes == null
                                ? null
                                : MemoryImage(_photoBytes!),
                            child: _photoBytes == null
                                ? const Icon(
                                    Icons.person_outline_rounded,
                                    size: 48,
                                    color: Color(0xFFB8C1CC),
                                  )
                                : null,
                          ),
                          Positioned(
                            right: -6,
                            bottom: -4,
                            child: IconButton.filled(
                              key: const ValueKey('choose-profile-photo'),
                              tooltip: 'Scegli foto profilo',
                              onPressed: _isSaving ? null : _pickPhoto,
                              icon: const Icon(Icons.add_a_photo_outlined),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_photoBytes != null) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _isSaving
                            ? null
                            : () => setState(() => _photoBytes = null),
                        child: const Text('Rimuovi foto'),
                      ),
                    ],
                    const SizedBox(height: 24),
                    TextFormField(
                      key: const ValueKey('profile-name'),
                      controller: _nameController,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 64,
                      decoration: const InputDecoration(
                        labelText: 'Nome',
                        hintText: 'Come vuoi essere chiamato?',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Inserisci un nome per continuare.'
                          : null,
                      onFieldSubmitted: (_) => _complete(),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _errorText!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFFFF9D95)),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      key: const ValueKey('complete-onboarding'),
                      onPressed: _isSaving ? null : _complete,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward_rounded),
                      label: const Text('Entra in Sylphy'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'La foto è facoltativa e rimane nello storage locale dell’app.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF858F9D), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<Uint8List?> _pickImageFile() async {
  const imageTypes = XTypeGroup(
    label: 'Immagini',
    extensions: ['jpg', 'jpeg', 'png', 'webp'],
    mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
  );
  final file = await openFile(acceptedTypeGroups: const [imageTypes]);
  return file?.readAsBytes();
}
