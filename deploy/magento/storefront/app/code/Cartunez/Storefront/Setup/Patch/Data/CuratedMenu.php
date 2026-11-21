<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Cartunez\Storefront\Block\Menu;
use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Creates Content > Blocks > cartunez-menu, the curated top menu, with the
 * launch items. An existing block is left as it is. Block\Menu explains the
 * line format.
 */
class CuratedMenu implements DataPatchInterface
{
    public function __construct(
        private readonly BlockFactory $blockFactory,
        private readonly BlockResource $blockResource
    ) {
    }

    public function apply(): self
    {
        $block = $this->blockFactory->create();
        $this->blockResource->load($block, Menu::BLOCK_ID, 'identifier');
        if ($block->getId()) {
            return $this;
        }
        $help = "# Top menu: one item per line, Label|target.\n"
            . "# target: finder (vehicle finder), brands (brand list), a category name,\n"
            . "# search:word, or a link (https://... or /path). Lines starting with # are notes.\n";
        $block->setIdentifier(Menu::BLOCK_ID)
            ->setTitle('Cartunez top menu')
            ->setStores([0])
            ->setIsActive(1)
            ->setContent($help . Menu::DEFAULT_LINES . "\n");
        $this->blockResource->save($block);
        return $this;
    }

    public static function getDependencies(): array
    {
        return [ShopDetails::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
