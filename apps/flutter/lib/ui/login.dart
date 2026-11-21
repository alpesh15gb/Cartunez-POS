import 'package:flutter/material.dart';

import '../core/billing.dart';
import '../main.dart';
import 'shift/pin_counter.dart';
import 'theme.dart';
import 'widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _api, _org, _branch;
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showServer = false;
  bool _hide = true;
  String? _error;

  /// This device's PIN counter set-up, if any; [_useEmail] shows the email form instead.
  Json? _counter;
  bool _useEmail = false;

  @override
  void initState() {
    super.initState();
    PinCounter.load().then((value) {
      if (mounted && value != null) setState(() => _counter = value);
    }).catchError((_) {});
    final c = context.appRead.connection;
    _api = TextEditingController(text: '${c['api'] ?? ''}');
    _org = TextEditingController(text: '${c['organizationId'] ?? ''}');
    _branch = TextEditingController(text: '${c['branchId'] ?? ''}');
    _showServer = '${c['organizationId'] ?? ''}'.isEmpty;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_form.currentState!.validate()) {
      setState(() => _showServer = true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.appRead.login(
        api: _api.text,
        organizationId: _org.text,
        branchId: _branch.text,
        email: _email.text,
        password: _password.text,
      );
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 820;
    final pin = _counter != null && !_useEmail;
    final card = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: pin
              ? PinSignIn(counter: _counter!, onUseEmail: () => setState(() => _useEmail = true))
              : Form(
            key: _form,
            child: AutofillGroup(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Sign in', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                Text(context.app.sessionProblem ?? 'Open your shop register.', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 22),
                TextFormField(
                  controller: _email,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your email' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password,
                  obscureText: _hide,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _hide ? 'Show password' : 'Hide password',
                      icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                  ),
                  validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _showServer = !_showServer),
                    icon: Icon(_showServer ? Icons.expand_less : Icons.storefront_outlined, size: 18),
                    label: Text(_showServer
                        ? 'Hide shop connection'
                        : 'Shop: ${_org.text.isEmpty ? 'not set' : '${_org.text} · ${_branch.text}'}'),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  child: _showServer
                      ? Column(children: [
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _api,
                            keyboardType: TextInputType.url,
                            decoration: const InputDecoration(labelText: 'Server address'),
                            validator: (v) => Uri.tryParse((v ?? '').trim())?.hasScheme == true ? null : 'Enter the server address',
                          ),
                          const SizedBox(height: 14),
                          Row(children: [
                            Expanded(
                              child: TextFormField(
                                controller: _org,
                                decoration: const InputDecoration(labelText: 'Organization code'),
                                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _branch,
                                decoration: const InputDecoration(labelText: 'Branch code'),
                                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                              ),
                            ),
                          ]),
                        ])
                      : const SizedBox.shrink(),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
                  ),
                const SizedBox(height: 18),
                if (_counter != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _useEmail = false),
                      icon: const Icon(Icons.dialpad, size: 18),
                      label: const Text('Sign in with PIN instead'),
                    ),
                  ),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Sign in'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    final brand = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      const BrandMark(size: 56),
      const SizedBox(height: 22),
      RichText(
        text: const TextSpan(
          style: TextStyle(fontSize: 52, fontWeight: FontWeight.w800, letterSpacing: -2.4, color: Colors.white),
          children: [TextSpan(text: 'Cartunez'), TextSpan(text: '.', style: TextStyle(color: Brand.lime))],
        ),
      ),
      const SizedBox(height: 8),
      const Text('Parts counter, stock and billing.', style: TextStyle(color: Color(0xFFB1C9BF), fontSize: 18)),
    ]);
    return Scaffold(
      backgroundColor: Brand.sidebar,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: wide
                ? Row(mainAxisSize: MainAxisSize.min, children: [brand, const SizedBox(width: 96), card])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const BrandMark(size: 44),
                    const SizedBox(height: 18),
                    card,
                  ]),
          ),
        ),
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: Brand.lime, borderRadius: BorderRadius.circular(size * 0.26)),
        child: CustomPaint(painter: _MarkPainter()),
      );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF1D3429);
    final w = size.width;
    for (final (x, h) in [(0.24, 0.44), (0.42, 0.31), (0.60, 0.44)]) {
      final path = Path()
        ..moveTo(w * (x + 0.06), w * (0.72 - h))
        ..lineTo(w * (x + 0.19), w * (0.72 - h))
        ..lineTo(w * (x + 0.13), w * 0.72)
        ..lineTo(w * x, w * 0.72)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
