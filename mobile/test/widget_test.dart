import 'package:flutter_test/flutter_test.dart';
import 'package:photobank_mobile/main.dart';

void main() {
  testWidgets('app builds', (tester) async {
    await tester.pumpWidget(const PhotobankApp());
    expect(find.byType(PhotobankApp), findsOneWidget);
  });
}
