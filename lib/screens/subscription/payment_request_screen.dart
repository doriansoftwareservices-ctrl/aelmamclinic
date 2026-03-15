import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/subscription_plan.dart';
import 'package:aelmamclinic/services/billing_service.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class PaymentRequestScreen extends StatefulWidget {
  const PaymentRequestScreen({
    super.key,
    required this.plan,
    required this.method,
  });

  final SubscriptionPlan plan;
  final PaymentMethod method;

  @override
  State<PaymentRequestScreen> createState() => _PaymentRequestScreenState();
}

class _PaymentRequestScreenState extends State<PaymentRequestScreen> {
  final BillingService _billing = BillingService();
  final NhostStorageService _storage = NhostStorageService();

  final TextEditingController _clinicNameCtrl = TextEditingController();
  final TextEditingController _referenceCtrl = TextEditingController();
  final TextEditingController _senderCtrl = TextEditingController();

  File? _proofFile;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillClinicName();
  }

  Future<void> _prefillClinicName() async {
    try {
      final profile = await ClinicProfileService.loadActiveOrFallback();
      if (!mounted) return;
      if (_clinicNameCtrl.text.trim().isEmpty && profile.nameAr.trim().isNotEmpty) {
        _clinicNameCtrl.text = profile.nameAr.trim();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _clinicNameCtrl.dispose();
    _referenceCtrl.dispose();
    _senderCtrl.dispose();
    _storage.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.image,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;
    final ext = (result.files.first.extension ?? '')
        .toLowerCase()
        .replaceAll('.', '');
    const allowed = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'};
    if (ext.isNotEmpty && !allowed.contains(ext)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('يرجى اختيار صورة فقط.')),
      );
      return;
    }
    setState(() => _proofFile = File(path));
  }

  Future<String?> _uploadProof() async {
    if (_proofFile == null) return null;
    final filename = _proofFile!.uri.pathSegments.last;
    final res = await _storage.uploadFile(
      file: _proofFile!,
      name: 'subscription_proof_${DateTime.now().millisecondsSinceEpoch}_$filename',
      bucketId: 'subscription-proofs',
    );
    final fileId = res['id']?.toString() ?? '';
    if (fileId.isEmpty) return null;
    return fileId;
  }

  Future<void> _submit() async {
    if (_submitting) return;

    if (_clinicNameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'يرجى إدخال اسم العيادة أولًا.');
      return;
    }
    if (_proofFile == null) {
      setState(() => _error = 'يرجى إرفاق إثبات الدفع أولًا.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final proofId = await _uploadProof();
      if (proofId == null || proofId.isEmpty) {
        throw Exception('تعذّر رفع الإثبات');
      }

      await _billing.createSubscriptionRequest(
        planCode: widget.plan.code,
        paymentMethodId: widget.method.id,
        proofUrl: proofId,
        clinicName: _clinicNameCtrl.text.trim(),
        referenceText: _referenceCtrl.text.trim(),
        senderName: _senderCtrl.text.trim(),
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mapSubmitError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _mapSubmitError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('forbidden')) return 'لا تملك صلاحية إرسال طلب الترقية.';
    if (msg.contains('plan not found') || msg.contains('invalid plan')) return 'الخطة غير متاحة حالياً.';
    if (msg.contains('payment_method is required')) return 'يرجى اختيار وسيلة الدفع.';
    if (msg.contains('account not found')) return 'تعذّر تحديد حساب المرفق الصحي.';
    if (msg.contains('not authenticated')) return 'يرجى تسجيل الدخول مرة أخرى.';
    return 'تعذّر إرسال الطلب: $error';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = widget.plan;
    final method = widget.method;

    final price = '\$${plan.priceUsd.toStringAsFixed(0)}';
    final proofLabel = _proofFile == null ? 'لم يتم إرفاق إثبات الدفع' : _proofFile!.uri.pathSegments.last;

    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          title: const LocalizedText('بيانات الدفع'),
          centerTitle: false,
        ),
        body: Stack(
          children: [
            _AnimatedBubbleBackdrop(scheme: scheme),
            SafeArea(
              child: Padding(
                padding: kScreenPadding,
                child: ListView(
                  children: [
                    _HeaderCard(
                      planName: plan.name,
                      price: price,
                      scheme: scheme,
                    ),
                    const SizedBox(height: 12),
                    _MethodCard(method: method),
                    const SizedBox(height: 12),

                    _SectionTitle(
                      title: 'معلومات التحويل',
                      subtitle: 'املأ البيانات ثم أرفق إثبات الدفع لإرسال الطلب.',
                    ),
                    const SizedBox(height: 10),

                    NeuField(
                      controller: _clinicNameCtrl,
                      labelText: context.trRaw('اسم العيادة'),
                      prefix: const Icon(Icons.local_hospital_outlined),
                    ),
                    const SizedBox(height: 10),
                    NeuField(
                      controller: _referenceCtrl,
                      labelText: context.trRaw('رقم العملية / مرجع التحويل'),
                      prefix: const Icon(Icons.confirmation_number_outlined),
                    ),
                    const SizedBox(height: 10),
                    NeuField(
                      controller: _senderCtrl,
                      labelText: context.trRaw('اسم المحوّل (اختياري)'),
                      prefix: const Icon(Icons.person_outline),
                    ),

                    const SizedBox(height: 14),

                    _AttachmentCard(
                      label: proofLabel,
                      hasFile: _proofFile != null,
                      onPick: _pickProof,
                      onClear: _proofFile == null
                          ? null
                          : () => setState(() => _proofFile = null),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      _ErrorBanner(text: _error!),
                    ],

                    const SizedBox(height: 16),

                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: scheme.onPrimary,
                                ),
                              )
                            : const Icon(Icons.send_rounded),
                        label: LocalizedText(
                          _submitting ? 'جارٍ الإرسال...' : 'إرسال الطلب',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    LocalizedText('عند إرسال الطلب سيتم مراجعته واعتماده من الإدارة.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface.withValues(alpha: 0.62),
                      ),
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedBubbleBackdrop extends StatefulWidget {
  const _AnimatedBubbleBackdrop({required this.scheme});
  final ColorScheme scheme;

  @override
  State<_AnimatedBubbleBackdrop> createState() =>
      _AnimatedBubbleBackdropState();
}

class _AnimatedBubbleBackdropState extends State<_AnimatedBubbleBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_BubbleParticle> _bubbles;
  Size _size = Size.zero;
  Duration? _lastTick;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _bubbles = _createBubbles(widget.scheme);
    _controller.addListener(_tick);
  }

  @override
  void didUpdateWidget(covariant _AnimatedBubbleBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scheme != widget.scheme) {
      _bubbles.clear();
      _bubbles.addAll(_createBubbles(widget.scheme));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_BubbleParticle> _createBubbles(ColorScheme scheme) {
    final rng = math.Random(42);
    return List.generate(28, (i) {
      final radius = 11 + rng.nextDouble() * 14;
      final x = rng.nextDouble();
      final y = rng.nextDouble();
      final speed = 8 + rng.nextDouble() * 14;
      final angle = rng.nextDouble() * math.pi * 2;
      final vx = math.cos(angle) * speed;
      final vy = math.sin(angle) * speed;
      final color = (i % 3 == 0
              ? scheme.primary
              : (i % 3 == 1 ? scheme.secondary : scheme.tertiary))
          .withValues(alpha: 0.18);
      return _BubbleParticle(
        pos: Offset(x, y),
        vel: Offset(vx, vy),
        radius: radius,
        color: color,
      );
    });
  }

  void _ensureSize(Size size) {
    if (_size == size || size.isEmpty) return;
    _size = size;
    for (final b in _bubbles) {
      if (!b.initialized) {
        b.pos = Offset(b.pos.dx * _size.width, b.pos.dy * _size.height);
        b.initialized = true;
      }
    }
  }

  void _tick() {
    if (!mounted || _size.isEmpty) return;
    final elapsed = _controller.lastElapsedDuration;
    if (elapsed == null) return;
    final last = _lastTick ?? elapsed;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0) return;
    _step(dt.clamp(0.0, 0.05));
  }

  void _step(double dt) {
    for (final b in _bubbles) {
      b.pos = Offset(b.pos.dx + b.vel.dx * dt, b.pos.dy + b.vel.dy * dt);

      if (b.pos.dx - b.radius < 0) {
        b.pos = Offset(b.radius, b.pos.dy);
        b.vel = Offset(-b.vel.dx, b.vel.dy);
      } else if (b.pos.dx + b.radius > _size.width) {
        b.pos = Offset(_size.width - b.radius, b.pos.dy);
        b.vel = Offset(-b.vel.dx, b.vel.dy);
      }
      if (b.pos.dy - b.radius < 0) {
        b.pos = Offset(b.pos.dx, b.radius);
        b.vel = Offset(b.vel.dx, -b.vel.dy);
      } else if (b.pos.dy + b.radius > _size.height) {
        b.pos = Offset(b.pos.dx, _size.height - b.radius);
        b.vel = Offset(b.vel.dx, -b.vel.dy);
      }
    }

    for (var i = 0; i < _bubbles.length; i++) {
      for (var j = i + 1; j < _bubbles.length; j++) {
        final a = _bubbles[i];
        final b = _bubbles[j];
        final dx = b.pos.dx - a.pos.dx;
        final dy = b.pos.dy - a.pos.dy;
        final dist = math.sqrt(dx * dx + dy * dy);
        final minDist = a.radius + b.radius;
        if (dist == 0 || dist >= minDist) continue;

        final nx = dx / dist;
        final ny = dy / dist;
        final rvx = b.vel.dx - a.vel.dx;
        final rvy = b.vel.dy - a.vel.dy;
        final velAlongNormal = rvx * nx + rvy * ny;

        if (velAlongNormal < 0) {
          final impulse = -velAlongNormal;
          a.vel = Offset(a.vel.dx - impulse * nx, a.vel.dy - impulse * ny);
          b.vel = Offset(b.vel.dx + impulse * nx, b.vel.dy + impulse * ny);
        }

        final overlap = minDist - dist;
        if (overlap > 0) {
          final correction = overlap / 2;
          a.pos = Offset(a.pos.dx - nx * correction, a.pos.dy - ny * correction);
          b.pos = Offset(b.pos.dx + nx * correction, b.pos.dy + ny * correction);
        }
      }
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _ensureSize(constraints.biggest);
          return CustomPaint(
            painter: _BubblePainter(
              bubbles: _bubbles,
              scheme: widget.scheme,
            ),
          );
        },
      ),
    );
  }
}

class _BubbleParticle {
  _BubbleParticle({
    required this.pos,
    required this.vel,
    required this.radius,
    required this.color,
  });

  Offset pos;
  Offset vel;
  final double radius;
  final Color color;
  bool initialized = false;
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.bubbles,
    required this.scheme,
  });

  final List<_BubbleParticle> bubbles;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bgPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          scheme.surface,
          scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          scheme.surface,
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    for (final bubble in bubbles) {
      final paint = Paint()..color = bubble.color;
      canvas.drawCircle(bubble.pos, bubble.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) {
    return oldDelegate.bubbles != bubbles || oldDelegate.scheme != scheme;
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.planName,
    required this.price,
    required this.scheme,
  });

  final String planName;
  final String price;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Colors.transparent,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.25),
          width: 0.7,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                colors: [
                  scheme.primary.withValues(alpha: 0.20),
                  scheme.secondary.withValues(alpha: 0.12),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.22)),
            ),
            child: Icon(Icons.workspace_premium_rounded, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LocalizedText('الخطة المطلوبة',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 4),
                LocalizedText(
                  planName,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: scheme.primary.withValues(alpha: 0.10),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
            ),
            child: Text(
              price,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({required this.method});
  final PaymentMethod method;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final hasLogo = method.logoUrl != null && method.logoUrl!.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Colors.transparent,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.25),
          width: 0.7,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.75),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
            ),
            child: hasLogo
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      method.logoUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.account_balance_rounded,
                        color: scheme.primary,
                      ),
                    ),
                  )
                : Icon(Icons.account_balance_rounded, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LocalizedText('وسيلة الدفع',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  method.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                LocalizedText('رقم الحساب: ${method.bankAccount}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface.withValues(alpha: 0.70),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
                LocalizedText(
                  title,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        LocalizedText(
          subtitle,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.25,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }
}

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.label,
    required this.hasFile,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final bool hasFile;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = hasFile ? scheme.primary : scheme.secondary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: scheme.surface.withValues(alpha: 0.86),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: accent.withValues(alpha: 0.12),
              border: Border.all(color: accent.withValues(alpha: 0.20)),
            ),
            child: Icon(
              hasFile ? Icons.verified_rounded : Icons.attach_file_rounded,
              color: accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: hasFile
                ? Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface
                          .withValues(alpha: hasFile ? 0.85 : 0.72),
                    ),
                  )
                : LocalizedText(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface
                          .withValues(alpha: hasFile ? 0.85 : 0.72),
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ✅ أبقينا NeuButton حتى لا نغير منطق/مكتبات، لكن بترتيب حديث داخل الكرت
              NeuButton.flat(
                label: hasFile ? 'تغيير' : 'إرفاق',
                onPressed: onPick,
              ),
              if (onClear != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onClear,
                  tooltip: context.trRaw('إزالة'),
                  icon: Icon(Icons.close_rounded, color: scheme.error),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.errorContainer.withValues(alpha: 0.55),
        border: Border.all(color: scheme.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
