<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Magento\Catalog\Model\Category;
use Magento\Catalog\Model\ResourceModel\Category\CollectionFactory;
use Magento\Cms\Model\Block as CmsBlock;
use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\ResourceModel\Block as CmsBlockResource;
use Magento\Framework\DataObject\IdentityInterface;
use Magento\Framework\View\Element\Template;
use Magento\Framework\View\Element\Template\Context;

/**
 * The curated top menu (desktop bar and the phone drawer), replacing Luma's
 * category menu. Edit it in Content > Blocks > cartunez-menu: one item per line,
 * "Label|target". Targets:
 *   finder           opens the vehicle finder ("Shop by car")
 *   brands           a dropdown of the brands (categories under "Brands")
 *   https://... or /path   that link
 *   search:word      a search for that word
 *   anything else    the category with that name (any level, case-insensitive),
 *                    or a search for the word when there is no such category.
 *                    Several names separated by commas are tried in order
 *                    ("Audio, Audio & Speakers, Car Audio"); the search uses the first.
 * A line without "|" uses the label as target. Lines starting with # are notes.
 */
class Menu extends Template implements IdentityInterface
{
    public const BLOCK_ID = 'cartunez-menu';
    public const DEFAULT_LINES = "Shop by Car|finder\n"
        . "Audio & Speakers|Audio, Audio & Speakers, Audio & Infotainment, Car Audio, Speakers\n"
        . "Lighting & Headlamps|Lighting, Lighting & Headlamps, Exterior & Lighting, Lights, Headlamps\n"
        . "Interior Makeovers|Interior, Interior Makeovers, Interior Accessories, Interiors\n"
        . "Performance & Filters|Performance, Performance & Filters, Performance & Detailing, Filters\n"
        . "Styling & Detailing|Styling, Styling & Detailing, Styling & Sun Control, Detailing, Car Care\n"
        . "Sale|Sale\n"
        . "Brands|brands\n"
        . "Studio Installation Booking|/contact";

    /** @var array<int, array{label: string, kind: string, url: string, children: array}>|null */
    private ?array $items = null;
    /** @var string[] */
    private array $tags = [];

    public function __construct(
        Context $context,
        private readonly BlockFactory $cmsBlocks,
        private readonly CmsBlockResource $cmsBlockResource,
        private readonly CollectionFactory $categories,
        array $data = []
    ) {
        parent::__construct($context, $data);
    }

    protected function _construct()
    {
        parent::_construct();
        $this->addData(['cache_lifetime' => 86400]);
    }

    public function getCacheKeyInfo()
    {
        return array_merge(parent::getCacheKeyInfo(), ['cz_menu']);
    }

    /** @return string[] lines "Label|target" from the CMS block, or the defaults */
    private function lines(): array
    {
        $text = '';
        $storeId = (int)$this->_storeManager->getStore()->getId();
        /** @var CmsBlock $cms */
        $cms = $this->cmsBlocks->create();
        $cms->setStoreId($storeId);
        $this->cmsBlockResource->load($cms, self::BLOCK_ID, 'identifier');
        if ($cms->getId()) {
            $this->tags = array_merge($this->tags, $cms->getIdentities());
            if ($cms->isActive()) {
                $text = (string)$cms->getContent();
            }
        } else {
            $this->tags[] = CmsBlock::CACHE_TAG;
        }
        // The editor may wrap lines in <p>, <div> or <br>: one item per line either way.
        $text = (string)preg_replace('#<(script|style)\b.*?</\1>#is', '', $text);
        $text = (string)preg_replace('#<br\s*/?>|</(p|div|li|h[1-6])>#i', "\n", $text);
        $text = html_entity_decode(strip_tags($text), ENT_QUOTES | ENT_HTML5, 'UTF-8');
        $lines = [];
        foreach (preg_split('/\R/', $text) ?: [] as $line) {
            $line = trim($line);
            if ($line !== '' && $line[0] !== '#') {
                $lines[] = $line;
            }
        }
        return $lines ?: explode("\n", self::DEFAULT_LINES);
    }

    /**
     * @return array<int, array{label: string, kind: string, url: string, children: array<int, array{label: string, url: string}>}>
     */
    public function getItems(): array
    {
        if ($this->items !== null) {
            return $this->items;
        }
        $parsed = [];
        $names = [];
        foreach ($this->lines() as $line) {
            [$label, $target] = array_map('trim', array_pad(explode('|', $line, 2), 2, ''));
            if ($label === '') {
                continue;
            }
            $target = $target === '' ? $label : $target;
            $parsed[] = [$label, $target];
            $lower = strtolower($target);
            if (!in_array($lower, ['finder', 'brands'], true) && !preg_match('#^(https?://|/|search:)#i', $target)) {
                foreach ($this->alternatives($target) as $name) {
                    $names[] = $name;
                }
            }
        }
        $found = $this->findCategories($names);
        $this->items = [];
        foreach ($parsed as [$label, $target]) {
            $lower = strtolower($target);
            $item = ['label' => $label, 'kind' => 'link', 'url' => '', 'children' => []];
            if ($lower === 'finder') {
                $item['kind'] = 'finder';
                $item['url'] = $this->getUrl('') . '#cz-finder';
            } elseif ($lower === 'brands') {
                $item['kind'] = 'brands';
                $item['url'] = $this->getUrl('') . '#cz-brands';
                $item['children'] = $this->brands();
                if (!$item['children']) {
                    continue; // no brand has parts yet
                }
            } elseif (preg_match('#^https?://#i', $target)) {
                $item['url'] = $target;
            } elseif ($target[0] === '/') {
                $item['url'] = $this->getUrl('') . ltrim($target, '/');
            } elseif (stripos($target, 'search:') === 0) {
                $item['url'] = $this->searchUrl(trim(substr($target, 7)));
            } else {
                $alternatives = $this->alternatives($target);
                foreach ($alternatives as $name) {
                    if (isset($found[mb_strtolower($name)])) {
                        $item['url'] = $found[mb_strtolower($name)];
                        break;
                    }
                }
                if ($item['url'] === '') {
                    $item['url'] = $this->searchUrl($alternatives[0] ?? $label);
                }
            }
            if ($item['kind'] === 'link' && ($lower === '/contact' || stripos($label, 'booking') !== false)) {
                $item['kind'] = 'studio';
            }
            if ($lower === 'sale' || strtolower($label) === 'sale') {
                $item['kind'] = $item['kind'] === 'link' ? 'sale' : $item['kind'];
            }
            $this->items[] = $item;
        }
        return $this->items;
    }

    /** @return string[] category names of a target ("category:" prefix optional, comma-separated) */
    private function alternatives(string $target): array
    {
        $target = (string)preg_replace('/^category:/i', '', $target);
        return array_values(array_filter(
            array_map('trim', explode(',', $target)),
            static fn (string $name): bool => $name !== ''
        ));
    }

    private function searchUrl(string $word): string
    {
        return $this->getUrl('catalogsearch/result', ['_query' => ['q' => $word]]);
    }

    /**
     * Active categories with these names in this store's tree, shallowest first.
     *
     * @param string[] $names
     * @return array<string, string> lowercase name => url
     */
    private function findCategories(array $names): array
    {
        $this->tags[] = Category::CACHE_TAG;
        if (!$names) {
            return [];
        }
        $store = $this->_storeManager->getStore();
        $collection = $this->categories->create()
            ->setStoreId((int)$store->getId())
            ->addAttributeToSelect(['name', 'url_key', 'url_path'])
            ->addAttributeToFilter('name', ['in' => array_values(array_unique($names))])
            ->addIsActiveFilter()
            ->addPathFilter('^1/' . (int)$store->getRootCategoryId() . '/')
            ->setOrder('level', 'ASC')
            ->setOrder('position', 'ASC');
        $urls = [];
        /** @var Category $category */
        foreach ($collection as $category) {
            $key = mb_strtolower(trim((string)$category->getName()));
            if (!isset($urls[$key])) {
                $urls[$key] = (string)$category->getUrl();
                $this->tags[] = Category::CACHE_TAG . '_' . (int)$category->getId();
            }
        }
        return $urls;
    }

    /** @return array<int, array{label: string, url: string}> brands with parts, A-Z */
    private function brands(): array
    {
        /** @var BrandCards $cards */
        $cards = $this->getLayout()->createBlock(BrandCards::class);
        $list = [];
        foreach ($cards->getBrands() as $brand) {
            $list[] = ['label' => $brand['name'], 'url' => $brand['url']];
        }
        $this->tags = array_merge($this->tags, $cards->getIdentities());
        usort($list, static fn (array $a, array $b): int => strnatcasecmp($a['label'], $b['label']));
        return $list;
    }

    public function getIdentities(): array
    {
        $this->getItems();
        return array_values(array_unique($this->tags));
    }
}
