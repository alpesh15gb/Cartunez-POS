<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Plugin;

use Cartunez\Storefront\Model\Catalog;
use Cartunez\Storefront\Model\Icons;
use Cartunez\Storefront\Model\ShopCategories;
use Magento\Catalog\Block\Product\AbstractProduct;
use Magento\Framework\Data\Collection;
use Magento\Framework\Escaper;

/**
 * Product cards in Magento's own lists (category and search pages, catalog
 * widgets, related parts) get the brand above the name ("Universal" or the
 * vehicle make when the part has no brand). Both list templates print
 * getProductDetailsHtml() for every card; the label is placed above the name
 * with CSS (.cz-card-brand, order: -1). Parts the studio fits (Audio, Interior,
 * Lighting, Installation departments) also get the cyan "Studio fitting" tag,
 * placed on the photo with CSS (.cz-card-badges); scripts.phtml adds "Save N%"
 * to the same corner. The labels of a whole list are loaded at once.
 */
class CardLabel
{
    /** @var array<int, true> lists already preloaded */
    private array $primed = [];

    public function __construct(
        private readonly Catalog $catalog,
        private readonly ShopCategories $shopCategories,
        private readonly Escaper $escaper
    ) {
    }

    /**
     * @param mixed $result
     * @param mixed $product
     * @return mixed
     */
    public function afterGetProductDetailsHtml(AbstractProduct $subject, $result, $product = null)
    {
        if (!is_object($product) || !method_exists($product, 'getId') || !$product->getId()) {
            return $result;
        }
        $this->prime($subject);
        $label = $this->catalog->cardLabel((int)$product->getId());
        $html = '';
        if ($label !== '') {
            $html .= '<span class="cz-card-brand">' . $this->escaper->escapeHtml($label) . '</span>';
        }
        if ($this->shopCategories->isStudioFit((int)$product->getId())) {
            $html .= '<span class="cz-card-badges"><span class="cz-tag cz-tag--studio">' . Icons::svg('wrench', 12)
                . $this->escaper->escapeHtml(__('Studio fitting')) . '</span></span>';
        }
        return $html . (string)$result;
    }

    private function prime(AbstractProduct $subject): void
    {
        $key = spl_object_id($subject);
        if (isset($this->primed[$key])) {
            return;
        }
        $this->primed[$key] = true;
        try {
            $collection = $subject->getData('product_collection');
            if (!$collection instanceof Collection && method_exists($subject, 'getLoadedProductCollection')) {
                $collection = $subject->getLoadedProductCollection();
            }
            if ($collection instanceof Collection && $collection->isLoaded()) {
                $ids = array_map('intval', array_keys($collection->getItems()));
                $this->catalog->preload($ids);
                $this->shopCategories->preloadProducts($ids);
            }
        } catch (\Throwable $e) {
            // Labels then load one by one.
        }
    }
}
