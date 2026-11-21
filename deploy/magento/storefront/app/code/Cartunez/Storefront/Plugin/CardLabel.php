<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Plugin;

use Cartunez\Storefront\Model\Catalog;
use Magento\Catalog\Block\Product\AbstractProduct;
use Magento\Framework\Data\Collection;
use Magento\Framework\Escaper;

/**
 * Product cards in Magento's own lists (category and search pages, catalog
 * widgets, related parts) get the brand above the name ("Universal" or the
 * vehicle make when the part has no brand). Both list templates print
 * getProductDetailsHtml() for every card; the label is placed above the name
 * with CSS (.cz-card-brand, order: -1). The labels of a whole list are loaded
 * at once.
 */
class CardLabel
{
    /** @var array<int, true> lists already preloaded */
    private array $primed = [];

    public function __construct(
        private readonly Catalog $catalog,
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
        if ($label === '') {
            return $result;
        }
        return '<span class="cz-card-brand">' . $this->escaper->escapeHtml($label) . '</span>' . (string)$result;
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
                $this->catalog->preload(array_map('intval', array_keys($collection->getItems())));
            }
        } catch (\Throwable $e) {
            // Labels then load one by one.
        }
    }
}
