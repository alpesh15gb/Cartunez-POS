<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Adds the "Shop by brand" cards to the home page, after the promo tiles.
 * The cards can be moved or removed in Content > Pages > Home Page.
 */
class BrandSection implements DataPatchInterface
{
    private const BLOCK = '{{block class="Cartunez\\Storefront\\Block\\BrandCards" '
        . 'template="Cartunez_Storefront::brands.phtml"}}';

    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly PageResource $pageResource
    ) {
    }

    public function apply(): self
    {
        $page = $this->pageFactory->create();
        $this->pageResource->load($page, 'home', 'identifier');
        $content = (string)$page->getContent();
        if (!$page->getId() || str_contains($content, 'BrandCards')) {
            return $this;
        }
        $anchor = '<div class="cz-section-head">';
        $at = strpos($content, $anchor);
        $content = $at === false
            ? $content . "\n" . self::BLOCK
            : substr($content, 0, $at) . self::BLOCK . "\n" . substr($content, $at);
        $page->setContent($content);
        $this->pageResource->save($page);
        return $this;
    }

    public static function getDependencies(): array
    {
        return [DarkStoreContent::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
