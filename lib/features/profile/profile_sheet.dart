import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/identity/identity_service.dart';
import '../../core/profile/user_profile.dart';

Future<void> showProfileSheet({
  required BuildContext context,
  required UserProfile profile,
  required IdentityService identityService,
  required VoidCallback onEditProfile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1E25),
    showDragHandle: true,
    builder: (sheetContext) => AnimatedBuilder(
      animation: identityService,
      builder: (context, _) => _ProfileSheetContent(
        profile: profile,
        identityService: identityService,
        onEditProfile: () {
          Navigator.of(sheetContext).pop();
          onEditProfile();
        },
      ),
    ),
  );
}

class _ProfileSheetContent extends StatelessWidget {
  const _ProfileSheetContent({
    required this.profile,
    required this.identityService,
    required this.onEditProfile,
  });

  final UserProfile profile;
  final IdentityService identityService;
  final VoidCallback onEditProfile;

  Future<void> _copyInvitation(BuildContext context, String invitation) async {
    await Clipboard.setData(ClipboardData(text: invitation));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ID Sylphy copiato. Ora puoi inviarlo alla persona.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = identityService.snapshot;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          4,
          24,
          28 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Il mio profilo',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 38,
                      backgroundColor: const Color(0xFF2A313B),
                      backgroundImage: profile.photoBytes == null
                          ? null
                          : MemoryImage(profile.photoBytes!),
                      child: profile.photoBytes == null
                          ? Text(
                              profile.initials,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.displayName,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Profilo locale Sylphy',
                            style: TextStyle(color: Color(0xFF9DA5B2)),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('edit-profile'),
                      tooltip: 'Modifica nome o foto',
                      onPressed: onEditProfile,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF11161D),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFF303741)),
                  ),
                  child: _IdentityContent(
                    snapshot: identity,
                    onRetry: identityService.initialize,
                    onCopy: (invitation) =>
                        _copyInvitation(context, invitation),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IdentityContent extends StatelessWidget {
  const _IdentityContent({
    required this.snapshot,
    required this.onRetry,
    required this.onCopy,
  });

  final IdentitySnapshot snapshot;
  final Future<void> Function() onRetry;
  final Future<void> Function(String invitation) onCopy;

  @override
  Widget build(BuildContext context) {
    if (snapshot.phase == IdentityPhase.loading) {
      return const Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 14),
          Expanded(child: Text('Creazione dell’identità sicura…')),
        ],
      );
    }
    if (snapshot.phase != IdentityPhase.ready) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ID Sylphy non disponibile',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            snapshot.phase == IdentityPhase.unavailable
                ? 'Il core nativo ABI 5 non è incluso in questa build.'
                : 'Non è stato possibile aprire il vault dell’identità (${snapshot.errorCode ?? 'errore sconosciuto'}).',
            style: const TextStyle(color: Color(0xFFAEB7C3), height: 1.4),
          ),
          if (snapshot.phase == IdentityPhase.error) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Riprova'),
            ),
          ],
        ],
      );
    }

    final id = snapshot.identityId!;
    final invitation = snapshot.invitationCode!;
    final expiration = snapshot.expiresAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.fingerprint_rounded, color: Color(0xFFCFF36A)),
            SizedBox(width: 10),
            Text(
              'IL TUO ID SYLPHY',
              style: TextStyle(
                color: Color(0xFFCFF36A),
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SelectableText(
          id,
          key: const ValueKey('profile-identity-id'),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Il pulsante copia il nuovo ID breve pubblicato su Veilid. La persona può incollarlo in “Aggiungi contatto”; Sylphy recupererà e verificherà automaticamente il bundle crittografico completo.',
          style: TextStyle(color: Color(0xFFAEB7C3), height: 1.4),
        ),
        if (expiration != null) ...[
          const SizedBox(height: 8),
          Text(
            'Invito valido fino al ${expiration.day}/${expiration.month}/${expiration.year}',
            style: const TextStyle(color: Color(0xFF858F9D), fontSize: 12),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('copy-profile-invitation'),
          onPressed: () => onCopy(invitation),
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copia ID Sylphy'),
        ),
      ],
    );
  }
}
