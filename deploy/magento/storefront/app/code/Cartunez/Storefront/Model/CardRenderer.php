<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Model;

use Magento\Catalog\Block\Product\AbstractProduct;
use Magento\Catalog\Model\Product;
use Magento\Catalog\Pricing\Price\FinalPrice;
use Magento\Catalog\Pricing\Price\RegularPrice;
use Magento\Framework\Escaper;

/**
 * One product card for the Cartunez lists (home rows, "Featured", "You may also
 * like"), in Magento's product-item markup so the cart widget and styles apply.
 * Shows only what the data says: "Save N%" when the selling price is below the
 * MRP, the cyan "Studio fitting" tag for parts the studio fits, stars only when
 * the part has reviews, then "Add to cart" and "Fit inquiry" (WhatsApp with the
 * part's name and link). Never any stock information.
 */
class CardRenderer
{
    public const WHATSAPP = 'https://wa.me/919949695030';

    public function __construct(
        private readonly Catalog $catalog,
        private readonly ShopCategories $shopCategories,
        private readonly Escaper $escaper
    ) {
    }

    /** @param Product[] $products */
    public function preload(array $products): void
    {
        $ids = array_map(static fn (Product $p): int => (int)$p->getId(), $products);
        $this->catalog->preload($ids);
        $this->shopCategories->preloadProducts($ids);
    }

    /** Whole percent below the MRP, or 0. */
    public function percentOff(Product $product): int
    {
        try {
            $info = $product->getPriceInfo();
            $selling = (float)$info->getPrice(FinalPrice::PRICE_CODE)->getAmount()->getValue();
            $mrp = (float)$info->getPrice(RegularPrice::PRICE_CODE)->getAmount()->getValue();
        } catch (\Throwable $e) {
            return 0;
        }
        if ($mrp <= 0 || $mrp - $selling < 0.01) {
            return 0;
        }
        return (int)floor(($mrp - $selling) * 100 / $mrp);
    }

    public function fitInquiryUrl(string $name, string $url): string
    {
        $text = (string)__('Hi Car Tunez, will this fit my car? %1 %2', $name, $url);
        return self::WHATSAPP . '?text=' . rawurlencode($text);
    }

    /**
     * @param array<string, string> $attributes extra attributes for the <li> (escaped here)
     */
    public function render(
        AbstractProduct $block,
        Product $product,
        string $imageId = 'category_page_grid',
        array $attributes = []
    ): string {
        $e = $this->escaper;
        $id = (int)$product->getId();
        $url = (string)$block->getProductUrl($product);
        $name = (string)$product->getName();
        $label = $this->catalog->cardLabel($id);
        $off = $this->percentOff($product);
        $studio = $this->shopCategories->isStudioFit($id);

        $attrs = '';
        foreach ($attributes as $key => $value) {
            $attrs .= ' ' . $e->escapeHtmlAttr($key) . '="' . $e->escapeHtmlAttr($value) . '"';
        }

        $badges = '';
        if ($off >= 1) {
            $badges .= '<span class="cz-badge">' . $e->escapeHtml(__('Save %1%', $off)) . '</span>';
        }
        if ($studio) {
            $badges .= '<span class="cz-tag cz-tag--studio">' . Icons::svg('wrench', 12)
                . $e->escapeHtml(__('Studio fitting')) . '</span>';
        }

        $canAdd = false;
        try {
            $canAdd = (bool)$product->getTypeInstance()->isPossibleBuyFromList($product);
        } catch (\Throwable $ex) {
            $canAdd = false;
        }
        if ($canAdd) {
            $buy = '<form data-role="tocart-form" action="' . $e->escapeUrl((string)$block->getAddToCartUrl($product))
                . '" method="post" data-mage-init=\'{"catalogAddToCart":{}}\'>'
                . '<input type="hidden" name="product" value="' . $id . '">'
                . $block->getBlockHtml('formkey')
                . '<button type="submit" class="action tocart primary" title="' . $e->escapeHtmlAttr((string)__('Add to cart')) . '">'
                . Icons::svg('bag', 16) . '<span>' . $e->escapeHtml(__('Add to cart')) . '</span></button></form>';
        } else {
            $buy = '<a class="action tocart primary" href="' . $e->escapeUrl($url) . '"><span>'
                . $e->escapeHtml(__('Choose options')) . '</span></a>';
        }

        return '<li class="item product product-item"' . $attrs . '>'
            . '<div class="product-item-info cz-card">'
            . '<a href="' . $e->escapeUrl($url) . '" class="product photo product-item-photo" tabindex="-1" aria-hidden="true">'
            . $block->getImage($product, $imageId)->toHtml() . '</a>'
            . ($badges !== '' ? '<span class="cz-card-badges">' . $badges . '</span>' : '')
            . '<div class="product details product-item-details">'
            . ($label !== '' ? '<span class="cz-card-brand">' . $e->escapeHtml($label) . '</span>' : '')
            . '<strong class="product name product-item-name"><a class="product-item-link" href="' . $e->escapeUrl($url) . '">'
            . $e->escapeHtml($name) . '</a></strong>'
            . (string)$block->getReviewsSummaryHtml($product, 'short')
            . (string)$block->getProductPriceHtml($product, FinalPrice::PRICE_CODE)
            . '<div class="product-item-inner"><div class="product actions product-item-actions"><div class="actions-primary">'
            . $buy
            . '<a class="cz-fit" href="' . $e->escapeUrl($this->fitInquiryUrl($name, $url)) . '" target="_blank" rel="noopener"'
            . ' data-cz-fit aria-label="' . $e->escapeHtmlAttr((string)__('Fit inquiry on WhatsApp: %1', $name)) . '">'
            . Icons::svg('chat', 16) . '<span>' . $e->escapeHtml(__('Fit inquiry')) . '</span></a>'
            . '</div></div></div>'
            . '</div></div></li>';
    }
}
