<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Cartunez\Storefront\Block\Menu;
use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Stitch design menu: Shop by Car, Audio & Speakers, Lighting & Headlamps,
 * Interior Makeovers, Performance & Filters, Styling & Detailing, Sale, Brands,
 * Studio Installation Booking (Block\Menu::DEFAULT_LINES). Content > Blocks >
 * cartunez-menu is replaced only while it still holds the launch default written
 * by CuratedMenu, so a menu the owner has edited is never touched. Running it
 * again changes nothing.
 */
class StitchMenu implements DataPatchInterface
{
    /** The launch menu written by CuratedMenu (before the Stitch design). */
    private const PREVIOUS_LINES = "Shop by car|finder\nAudio|Audio\nLighting|Lighting\nInterior|Interior\n"
        . "Car care|Car care\nSale|Sale\nBrands|brands";

    private const HELP = "# Top menu: one item per line, Label|target.\n"
        . "# target: finder (vehicle finder), brands (brand list), a category name,\n"
        . "# search:word, or a link (https://... or /path). Lines starting with # are notes.\n";

    private const HELP_NAMES = "# Several category names separated by commas are tried in order; the search uses the first.\n";

    public function __construct(
        private readonly BlockFactory $blockFactory,
        private readonly BlockResource $blockResource
    ) {
    }

    public function apply(): self
    {
        $block = $this->blockFactory->create();
        $this->blockResource->load($block, Menu::BLOCK_ID, 'identifier');
        $new = self::HELP . self::HELP_NAMES . Menu::DEFAULT_LINES . "\n";
        if (!$block->getId()) {
            $block->setIdentifier(Menu::BLOCK_ID)
                ->setTitle('Cartunez top menu')
                ->setStores([0])
                ->setIsActive(1)
                ->setContent($new);
            $this->blockResource->save($block);
            return $this;
        }
        $current = $this->normalize((string)$block->getContent());
        $previous = [
            $this->normalize(self::HELP . self::PREVIOUS_LINES . "\n"),
            $this->normalize(self::PREVIOUS_LINES),
        ];
        if (in_array($current, $previous, true)) {
            $block->setContent($new);
            $this->blockResource->save($block);
        }
        return $this;
    }

    /** Same text whatever the line endings and surrounding blank space. */
    private function normalize(string $text): string
    {
        $lines = array_map('trim', preg_split('/\R/', $text) ?: []);
        return implode("\n", array_values(array_filter($lines, static fn (string $l): bool => $l !== '')));
    }

    public static function getDependencies(): array
    {
        return [CuratedMenu::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
