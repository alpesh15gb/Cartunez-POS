<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Adds the "On sale" section to the home page, right after the category
 * tiles (before the brands and featured products). It shows the parts the
 * POS put on sale and is empty while nothing is on sale. It can be moved or
 * removed in Content > Pages > Home Page.
 */
class SaleSection implements DataPatchInterface
{
    private const BLOCK = '{{block class="Cartunez\\Storefront\\Block\\SaleProducts" '
        . 'template="Cartunez_Storefront::sale.phtml"}}';

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
        if (!$page->getId() || str_contains($content, 'SaleProducts')) {
            return $this;
        }
        $page->setContent($this->insert($content));
        $this->pageResource->save($page);
        return $this;
    }

    /** After the category tiles; else before the brands or "Featured products"; else at the end. */
    private function insert(string $content): string
    {
        $tiles = strpos($content, '<div class="cz-promos">');
        if ($tiles !== false) {
            $end = $this->closingDiv($content, $tiles);
            if ($end !== null) {
                return substr($content, 0, $end) . "\n" . self::BLOCK . substr($content, $end);
            }
        }
        $brands = strpos($content, 'Block\\BrandCards');
        if ($brands !== false) {
            $at = strrpos(substr($content, 0, $brands), '{{block');
            if ($at !== false) {
                return substr($content, 0, $at) . self::BLOCK . "\n" . substr($content, $at);
            }
        }
        $featured = strpos($content, 'In stock now');
        if ($featured !== false) {
            $at = strrpos(substr($content, 0, $featured), '<div class="cz-section-head">');
            if ($at !== false) {
                return substr($content, 0, $at) . self::BLOCK . "\n" . substr($content, $at);
            }
        }
        return $content . "\n" . self::BLOCK;
    }

    /** Offset just after the </div> that closes the <div> starting at [start], or null. */
    private function closingDiv(string $content, int $start): ?int
    {
        $depth = 0;
        $offset = $start;
        while (preg_match('/<div\b|<\/div>/i', $content, $match, PREG_OFFSET_CAPTURE, $offset) === 1) {
            $tag = $match[0][0];
            $at = (int)$match[0][1];
            $depth += strtolower($tag) === '</div>' ? -1 : 1;
            $offset = $at + strlen($tag);
            if ($depth === 0) {
                return $offset;
            }
        }
        return null;
    }

    public static function getDependencies(): array
    {
        return [PremiumStoreContent::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
