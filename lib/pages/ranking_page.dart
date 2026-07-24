import "package:flutter/material.dart";
import "package:novvera/components/components.dart";
import "package:novvera/foundation/app.dart";
import "package:novvera/foundation/book_source/book_source.dart";
import "package:novvera/utils/translations.dart";

class RankingPage extends StatefulWidget {
  const RankingPage({required this.categoryKey, super.key});

  final String categoryKey;

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  late final CategoryBooksData data;
  late final Map<String, String> options;
  late String optionValue;

  void findData() {
    for (final source in BookSource.all()) {
      if (source.categoryData?.key == widget.categoryKey) {
        data = source.categoryBooksData!;
        options = data.rankingData!.options;
        optionValue = options.keys.first;
        return;
      }
    }
    throw "${widget.categoryKey} Not found";
  }

  @override
  void initState() {
    findData();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var topPadding = context.padding.top + 56;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: Appbar(
        title: Text("Ranking".tl),
      ),
      body: BookList(
        key: Key(optionValue),
        errorLeading: SizedBox(height: topPadding),
        leadingSliver:
            buildOptions().sliverPadding(EdgeInsets.only(top: topPadding)),
        loadPage: data.rankingData!.load == null
            ? null
            : (i) => data.rankingData!.load!(optionValue, i),
        loadNext: data.rankingData!.loadWithNext == null
            ? null
            : (i) => data.rankingData!.loadWithNext!(optionValue, i),
      ),
    );
  }

  Widget buildOptionItem(String text, String value, BuildContext context) {
    return OptionChip(
      text: text,
      isSelected: value == optionValue,
      onTap: () {
        if (value == optionValue) return;
        setState(() {
          optionValue = value;
        });
      },
    );
  }

  Widget buildOptions() {
    List<Widget> children = [];
    children.add(Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var option in options.entries)
          buildOptionItem(option.value.tl, option.key, context)
      ],
    ));
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [...children, const Divider()],
      ).paddingLeft(8).paddingRight(8),
    );
  }
}
