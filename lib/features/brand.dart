import 'package:flutter/material.dart';

class BrandMark extends StatelessWidget {
  final double size;

  const BrandMark({super.key, this.size = 46});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.asset(
        'assets/brand/logo.png',
        width: size,
        height: size,
        semanticLabel: 'CodeRelay',
      ),
    );
  }
}
