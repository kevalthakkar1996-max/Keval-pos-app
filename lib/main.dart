import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  runApp(const KevalPosApp());
}

class KevalPosApp extends StatelessWidget {
  const KevalPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Keval POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.indigo, useMaterial3: true),
      home: const PosDashboard(storeId: 'keval_store_01'),
    );
  }
}

class CartItem {
  final String id;
  final String name;
  final double mrp;
  final double floorPrice;
  double salePrice;
  int quantity;

  CartItem({
    required this.id,
    required this.name,
    required this.mrp,
    required this.floorPrice,
    required this.salePrice,
    this.quantity = 1,
  });
}

class PosDashboard extends StatefulWidget {
  final String storeId;
  const PosDashboard({super.key, required this.storeId});

  @override
  State<PosDashboard> createState() => _PosDashboardState();
}

class _PosDashboardState extends State<PosDashboard> {
  String billingMode = 'NON_GST'; // NON_GST, GST, SILENT
  bool isAdmin = false;
  final List<CartItem> cart = [];
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  String _searchQuery = '';

  double get subtotal => cart.fold(0, (sum, item) => sum + (item.salePrice * item.quantity));
  double get tax => billingMode == 'GST' ? subtotal * 0.18 : 0.0;
  double get total => subtotal + tax;

  void addToCart(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final existingIndex = cart.indexWhere((item) => item.id == doc.id);

    if (existingIndex >= 0) {
      setState(() => cart[existingIndex].quantity++);
    } else {
      setState(() {
        cart.add(CartItem(
          id: doc.id,
          name: data['name'] ?? 'Product',
          mrp: (data['mrp'] ?? 0.0).toDouble(),
          floorPrice: (data['floorPrice'] ?? 0.0).toDouble(),
          salePrice: (data['mrp'] ?? 0.0).toDouble(),
        ));
      });
    }
  }

  void _listenVoice() async {
    if (!_isListening) {
      bool available = await _speech.initialize();
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(onResult: (val) {
          setState(() {
            _searchQuery = val.recognizedWords;
            if (val.hasConfidenceRating && val.confidence > 0) {
              _isListening = false;
            }
          });
        });
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  void _openBarcodeScanner() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: 400,
        child: MobileScanner(
          onDetect: (capture) {
            final barcodes = capture.barcodes;
            for (final barcode in barcodes) {
              if (barcode.rawValue != null) {
                FirebaseFirestore.instance
                    .collection('stores')
                    .doc(widget.storeId)
                    .collection('products')
                    .where('barcode', isEqualTo: barcode.rawValue)
                    .limit(1)
                    .get()
                    .then((snap) {
                  if (snap.docs.isNotEmpty) {
                    addToCart(snap.docs.first);
                    Navigator.pop(ctx);
                  }
                });
                break;
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> checkout(String paymentMode) async {
    if (cart.isEmpty) return;

    final batch = FirebaseFirestore.instance.batch();
    final storeRef = FirebaseFirestore.instance.collection('stores').doc(widget.storeId);
    final invoiceRef = storeRef.collection('invoices').doc();

    batch.set(invoiceRef, {
      'billingMode': billingMode,
      'paymentMode': paymentMode,
      'subtotal': subtotal,
      'tax': tax,
      'total': total,
      'createdAt': FieldValue.serverTimestamp(),
      'items': cart.map((i) => {
        'id': i.id,
        'name': i.name,
        'qty': i.quantity,
        'price': i.salePrice,
      }).toList(),
    });

    for (var item in cart) {
      final productRef = storeRef.collection('products').doc(item.id);
      batch.update(productRef, {
        'stock': FieldValue.increment(-item.quantity),
      });
    }

    if (paymentMode == 'KHATA') {
      final khataRef = storeRef.collection('khata').doc();
      batch.set(khataRef, {
        'type': 'DEBIT',
        'amount': total,
        'invoiceId': invoiceRef.id,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();

    if (billingMode != 'SILENT') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invoice Created & Printing Triggered!')),
      );
    }

    setState(() => cart.clear());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('POS - ${widget.storeId}'),
        actions: [
          DropdownButton<String>(
            value: billingMode,
            underline: const SizedBox(),
            items: ['NON_GST', 'GST', 'SILENT'].map((mode) {
              return DropdownMenuItem(value: mode, child: Text(mode));
            }).toList(),
            onChanged: (val) => setState(() => billingMode = val!),
          ),
          IconButton(
            icon: Icon(isAdmin ? Icons.admin_panel_settings : Icons.person),
            onPressed: () => setState(() => isAdmin = !isAdmin),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Search product...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: IconButton(
                              icon: Icon(_isListening ? Icons.mic : Icons.mic_none),
                              onPressed: _listenVoice,
                            ),
                          ),
                          onChanged: (val) => setState(() => _searchQuery = val),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        onPressed: _openBarcodeScanner,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('stores')
                        .doc(widget.storeId)
                        .collection('products')
                        .snapshots(),
                    builder: (ctx, snap) {
                      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                      final docs = snap.data!.docs.where((d) {
                        final name = (d['name'] ?? '').toString().toLowerCase();
                        return name.contains(_searchQuery.toLowerCase());
                      }).toList();

                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (ctx, i) {
                          final data = docs[i].data() as Map<String, dynamic>;
                          final int stock = data['stock'] ?? 0;
                          return ListTile(
                            title: Text(data['name'] ?? ''),
                            subtitle: Text('₹${data['mrp']} | Stock: $stock'),
                            trailing: stock <= 5
                                ? const Chip(
                                    label: Text('Low Stock', style: TextStyle(color: Colors.white)),
                                    backgroundColor: Colors.red,
                                  )
                                : null,
                            onTap: () => addToCart(docs[i]),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                const ListTile(title: Text('Cart', style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(
                  child: ListView.builder(
                    itemCount: cart.length,
                    itemBuilder: (ctx, i) {
                      final item = cart[i];
                      return ListTile(
                        title: Text(item.name),
                        subtitle: Text('Qty: ${item.quantity} x ₹${item.salePrice}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => setState(() => cart.removeAt(i)),
                        ),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.grey.shade100,
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [const Text('Total:'), Text('₹${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => checkout('CASH'),
                              child: const Text('Cash'),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => checkout('UPI'),
                              child: const Text('UPI'),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => checkout('KHATA'),
                              child: const Text('Khata'),
                            ),
                          ),
                        ],
                      ),
                    ],
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
